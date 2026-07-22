import SwiftUI

// The question/permission page: what the waiting session is blocked on,
// answerable in place when the answer hook is installed. All wizard rules
// live in AnswerFlow (Core) so they're unit-tested; this view only forwards
// events and writes the answer file on completion.
struct DecisionPaneView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var uiModel: NotchUIModel
    let session: SessionInfo
    let prompt: PendingPrompt
    let clickToAnswerReady: Bool
    @Binding var showSessionsInstead: Bool

    @State private var flow = AnswerFlow()

    var body: some View {
        let clickable = prompt.answerable && clickToAnswerReady && !flow.answersSent
        paneBody(clickable: clickable)
            .onChange(of: prompt) { _, _ in
                flow.reset()
            }
            // The question page gets a taller panel so long questions and
            // option lists breathe.
            .onAppear { uiModel.decisionPane = true }
            .onDisappear { uiModel.decisionPane = false }
    }

    // MARK: - Answer plumbing

    private func commitAnswer(_ value: String) {
        if let answers = flow.commit(value, prompt: prompt) {
            HookCapture.writeAnswer(sessionId: session.id, answers: answers, promptId: prompt.promptId)
        }
    }

    // An option row tap. Permission prompts route by the row's decision:
    // Yes rows send immediately; the No row opens the feedback field first
    // (terminal parity — "No, and tell Claude what to do differently"
    // collects a message; sending it empty is a plain deny).
    private func tapOption(_ option: String) {
        guard prompt.isPermission else {
            return commitAnswer(option)
        }
        guard let choice = prompt.permissionChoices.first(where: { $0.label == option }) else { return }
        // Keep the tapped row highlighted so the frozen pane shows what was sent.
        flow.selectedLabels = [option]
        if choice.decision == .deny {
            flow.freeTextActive = true
            return
        }
        sendPermission(choice.decision, message: nil, recording: option)
    }

    // Freezes the wizard via the same commit path as questions (so the pane
    // shows the sent state), then writes the permission answer file the
    // blocking hook is polling for.
    private func sendPermission(_ decision: PermissionDecision, message: String?,
                                recording value: String) {
        guard flow.commit(value, prompt: prompt) != nil else { return }
        HookCapture.writePermissionAnswer(
            sessionId: session.id,
            toolName: prompt.toolName,
            inputSignature: prompt.inputSignature,
            decision: decision,
            message: message,
            promptId: prompt.promptId
        )
    }

    private func submitFreeText() {
        let text = flow.freeTextDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.isPermission {
            // The field only exists behind the No row: typed text is the
            // deny's feedback, an empty send is a plain deny. Never map the
            // typed text back onto option labels — typing "Yes" here must
            // still deny.
            guard let deny = prompt.permissionChoices.first(where: { $0.decision == .deny }) else { return }
            sendPermission(.deny, message: text.isEmpty ? nil : text,
                           recording: text.isEmpty ? deny.label : text)
            return
        }
        guard !text.isEmpty else { return }
        commitAnswer(text)
    }

    private func commitMultiAnswer() {
        if let answers = flow.commitMulti(prompt: prompt) {
            HookCapture.writeAnswer(sessionId: session.id, answers: answers, promptId: prompt.promptId)
        }
    }

    // MARK: - Layout

    private func paneBody(clickable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Centered session context: title row, model/context caption below.
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.attentionBeige)
                        .frame(width: 7, height: 7)
                    Text(session.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(sessionCaption)
                    .font(.system(size: 9))
                    .foregroundColor(session.contextIsHigh ? appState.colors.waiting : .gray)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)

            Rectangle()
                .fill(Color.islandHairline)
                .frame(height: 1)

            let current = clickable ? flow.currentQuestion(of: prompt) : nil
            if clickable, prompt.allQuestions.count > 1 {
                stepperWizard
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(current?.header ?? prompt.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                    if !clickable, prompt.allQuestions.count > 1 {
                        Text("· question 1 of \(prompt.allQuestions.count)")
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                    }
                }
                if current?.isMultiSelect ?? prompt.isMultiSelect {
                    Text("select multiple")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.gray)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
                }
            }
            // Everything content-sized scrolls together; only the pinned
            // hint stays fixed, so a long question can't be squeezed to a
            // one-line strip by the option rows.
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(current?.question ?? prompt.detail)
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    let options = current?.options ?? prompt.options
                    if !options.isEmpty {
                        // Vertical rows: full width per option so labels
                        // wrap instead of truncating in grid cells.
                        VStack(alignment: .leading, spacing: 5) {
                            // Index identity: duplicate labels must not collide.
                            ForEach(Array(options.prefix(8).enumerated()), id: \.offset) { _, option in
                                optionChip(
                                    option,
                                    isMultiSelect: current?.isMultiSelect ?? prompt.isMultiSelect,
                                    clickable: clickable
                                )
                            }
                        }
                    }
                    // Permission prompts have no standalone "type something"
                    // row — the No option is the feedback entry point, so the
                    // field only appears once that row was clicked.
                    if clickable, !prompt.isPermission || flow.freeTextActive {
                        freeTextRow(isMultiSelect: current?.isMultiSelect ?? prompt.isMultiSelect)
                    }
                    if !clickable, prompt.extraQuestionCount > 0 {
                        Text("+\(prompt.extraQuestionCount) more question\(prompt.extraQuestionCount == 1 ? "" : "s") after this one")
                            .font(.system(size: 9))
                            .foregroundColor(.gray)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ZStack {
                // Centered navigation; session actions stay tucked at the
                // trailing edge. Pinned outside the scroll so the controls
                // never disappear under long option lists.
                HStack(spacing: 10) {
                    if flow.answersSent {
                        Text(prompt.allQuestions.count > 1 ? "Answers sent" : "Answer sent")
                            .font(.system(size: 9))
                            .foregroundColor(.gray)
                    } else if clickable {
                        if prompt.allQuestions.count > 1 {
                            NavPill(title: "‹ Previous", enabled: flow.questionIndex > 0) {
                                flow.goTo(flow.questionIndex - 1, prompt: prompt)
                            }
                        }
                        if current?.isMultiSelect == true {
                            Button {
                                commitMultiAnswer()
                            } label: {
                                Text(flow.questionIndex + 1 < prompt.allQuestions.count ? "Next question" : "Send answer")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(flow.multiAnswerIsEmpty ? .gray : .black)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule().fill(flow.multiAnswerIsEmpty
                                            ? Color.islandChipFill : Color.attentionBeige)
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(flow.multiAnswerIsEmpty)
                        } else if prompt.allQuestions.count > 1 {
                            NavPill(title: "Next ›",
                                    enabled: flow.canVisit(flow.questionIndex + 1, prompt: prompt)) {
                                flow.goTo(flow.questionIndex + 1, prompt: prompt)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                HStack(spacing: 0) {
                    Spacer()
                    IslandActionButton("Sessions") { showSessionsInstead = true }
                    IslandActionButton("Settings") { uiModel.showingSettings = true }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // Wizard breadcrumb over the question: every step by name, answered
    // steps checked, the current one lit. Steps are buttons — click any
    // visited step to go back (or forward again) and revise its answer.
    private var stepperWizard: some View {
        HStack(spacing: 6) {
            ForEach(Array(prompt.allQuestions.enumerated()), id: \.offset) { index, question in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundColor(.gray.opacity(0.6))
                }
                Button {
                    flow.goTo(index, prompt: prompt)
                } label: {
                    HStack(spacing: 4) {
                        if flow.answersByIndex[index] != nil, index != flow.questionIndex {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                        } else {
                            Text("\(index + 1)")
                                .font(.system(size: 8, weight: .bold))
                                .frame(width: 13, height: 13)
                                .background(
                                    Circle().stroke(
                                        index == flow.questionIndex
                                            ? Color.white.opacity(0.6) : Color.gray.opacity(0.5),
                                        lineWidth: 1
                                    )
                                )
                        }
                        Text(question.header)
                            .font(.system(size: 9, weight: index == flow.questionIndex ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    .foregroundColor(index == flow.questionIndex ? .white : .gray)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!flow.canVisit(index, prompt: prompt))
                .layoutPriority(index == flow.questionIndex ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // "Fable · xhigh · 34% context · ~/Documents/app" — the caption under
    // the session title on the question page.
    private var sessionCaption: String {
        var parts: [String] = []
        if let runtime = session.runtimeLine { parts.append(runtime) }
        parts.append(session.cwd.abbreviatingHomeDirectory)
        return parts.joined(separator: " · ")
    }

    // A row answers on click (single-select, advancing the stepper) or
    // toggles (multi-select). Display-only when the answer hook isn't
    // installed or the answers were already sent.
    @ViewBuilder
    private func optionChip(_ option: String, isMultiSelect: Bool, clickable: Bool) -> some View {
        let isSelected = flow.selectedLabels.contains(option)
        let chip = HStack(alignment: .top, spacing: 7) {
            // A checkbox is the "you can pick several" signal; single-select
            // rows stay plain so the two modes read differently at a glance.
            if isMultiSelect {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .black : Color.white.opacity(clickable ? 0.55 : 0.3))
                    .padding(.top, 1)
            }
            Text(option)
                .font(.system(size: 11))
                .foregroundColor(isSelected ? .black : .white)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9).fill(Color.attentionBeige)
                } else {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.white.opacity(clickable ? 0.3 : 0.15), lineWidth: 1)
                }
            }
        if clickable {
            Button {
                if isMultiSelect {
                    if !flow.selectedLabels.insert(option).inserted {
                        flow.selectedLabels.remove(option)
                    }
                } else {
                    tapOption(option)
                }
            } label: {
                chip.contentShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
        } else {
            chip
        }
    }

    // "Type something…" — the terminal dialog offers free text, so the
    // island does too. Verified legal: non-label answers are accepted
    // verbatim by Claude Code.
    @ViewBuilder
    private func freeTextRow(isMultiSelect: Bool) -> some View {
        if flow.freeTextActive {
            HStack(spacing: 6) {
                TextField(
                    prompt.isPermission
                        ? "Tell Claude what to do differently…"
                        : (isMultiSelect ? "Add your own…" : "Type your answer…"),
                    text: $flow.freeTextDraft
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.1))
                    )
                    .onSubmit {
                        if isMultiSelect {
                            commitMultiAnswer()
                        } else {
                            submitFreeText()
                        }
                    }
                // Multi-select has ONE submit — the pinned button collects
                // checks and typed text together; no second Send here.
                if !isMultiSelect {
                    Button {
                        submitFreeText()
                    } label: {
                        Text(flow.questionIndex + 1 < prompt.allQuestions.count ? "Next" : "Send")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.attentionBeige))
                    }
                    .buttonStyle(.plain)
                    // A deny's feedback is optional (empty = plain deny, like
                    // pressing enter on the terminal's No row); question
                    // answers still need actual text.
                    .disabled(!prompt.isPermission
                        && flow.freeTextDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } else {
            Button {
                flow.freeTextActive = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 9))
                    Text("Type something…")
                        .font(.system(size: 11))
                }
                .foregroundColor(.gray)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.gray.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                .contentShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
        }
    }
}
