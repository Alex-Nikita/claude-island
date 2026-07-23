import SwiftUI
import AppKit

// The island's main pane: tab rail on the left, session header + the
// selected capability list (subagents/skills/hooks) on the right.
struct CapabilityBrowserView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var uiModel: NotchUIModel
    @Binding var showSessionPicker: Bool
    @Binding var showSessionsInstead: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            tabRail
                .frame(width: 92)
            Rectangle()
                .fill(Color.islandHairline)
                .frame(width: 1)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    sessionHeader
                    Spacer(minLength: 0)
                }
                Rectangle()
                    .fill(Color.islandHairline)
                    .frame(height: 1)
                    .padding(.horizontal, 24)
                if uiModel.selectedTab != .hooks {
                    HStack {
                        Spacer()
                        activeFilterToggle
                    }
                }
                capabilityList
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Session identity block centered at the top of the content column:
    // chevrons flank it like the old header, the name opens the dropdown,
    // the runtime line opens the context page.
    @ViewBuilder
    private var sessionHeader: some View {
        if let session = appState.selectedSession {
            HStack(spacing: 8) {
                ChevronButton("chevron.left") { appState.selectPreviousSession() }
                VStack(spacing: 2) {
                    Button {
                        showSessionPicker.toggle()
                    } label: {
                        // Cap the ROW, not the text: a flexible frame on the
                        // Text absorbs slack and strands the dot far from a
                        // centered name. The row hugs its content and only
                        // truncates past the cap.
                        HStack(spacing: 5) {
                            StatusDot(
                                color: session.statusColor(appState.colors),
                                pulsing: session.isActivelyWorking || session.needsAttention,
                                symbol: session.statusSymbol(symbolsEnabled: appState.symbolsEnabled)
                            )
                            Text(session.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(.gray)
                                .rotationEffect(.degrees(showSessionPicker ? 180 : 0))
                        }
                        .frame(maxWidth: 380)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(session.displayStatus)
                    if let runtime = session.runtimeLine {
                        Button {
                            uiModel.showingContext = true
                        } label: {
                            Text(runtime + " ›")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(session.contextIsHigh ? appState.colors.waiting : .gray)
                                .lineLimit(1)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show context window details")
                    }
                    Text("\(URL(fileURLWithPath: session.cwd).lastPathComponent) · \(appState.selectedSessionIndex + 1) of \(appState.sessions.count)")
                        .font(.system(size: 9))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                ChevronButton("chevron.right") { appState.selectNextSession() }
            }
        } else {
            Text("No active sessions")
                .font(.system(size: 11))
                .foregroundColor(.gray)
        }
    }

    private var tabRail: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(CapabilityTab.allCases) { tab in
                Button {
                    uiModel.selectedTab = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(uiModel.selectedTab == tab ? .white : .gray)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(uiModel.selectedTab == tab ? Color.claudeOrange : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Rectangle()
                .fill(Color.islandHairline)
                .frame(width: 56, height: 1)
                .padding(.leading, 10)
                .padding(.bottom, 3)
            if showSessionsInstead, appState.needsUserAttention {
                IslandActionButton("Show prompt") { showSessionsInstead = false }
            }
            // Without these, notch mode would be a one-way door: the settings
            // popover only exists in pill mode.
            HStack(spacing: 5) {
                IslandActionButton("Settings") { uiModel.showingSettings = true }
                if appState.hasUpdate {
                    Circle().fill(Color.updateAccent).frame(width: 7, height: 7)
                }
            }
            IslandActionButton("Pill mode") { appState.settings.displayMode = .pill }
            IslandActionButton("Quit") { NSApp.terminate(nil) }
        }
    }

    private var activeFilterToggle: some View {
        Button {
            uiModel.onlyActive.toggle()
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(uiModel.onlyActive ? Color.green : Color.gray.opacity(0.7))
                    .frame(width: 6, height: 6)
                Text("Active only")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(uiModel.onlyActive ? .white : .gray)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(uiModel.onlyActive ? Color.green.opacity(0.22) : Color.white.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show only skills in use and subagents currently running")
    }

    private var capabilityList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                switch uiModel.selectedTab {
                case .subagents: subagentRows
                case .skills: skillRows
                case .hooks: hookRows
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Skills

    // Skill events carry names like "plugin:skill" or "dir:skill"; the
    // scanned list holds bare names — match on the last ":" segment too.
    private func isSkillActive(_ skill: SkillInfo, in active: [String]) -> Bool {
        active.contains { $0 == skill.name || $0.hasSuffix(":" + skill.name) }
    }

    @ViewBuilder
    private var skillRows: some View {
        let activeNames = appState.selectedSession?.activeUse.skills ?? []
        let skills = appState.capabilities?.skills ?? []
        let unlisted = activeNames.filter { name in
            !skills.contains { isSkillActive($0, in: [name]) }
        }
        if uiModel.onlyActive && unlisted.isEmpty && !skills.contains(where: { isSkillActive($0, in: activeNames) }) {
            NothingActiveNote()
        } else if skills.isEmpty && unlisted.isEmpty {
            CapabilityEmptyState(
                symbol: "sparkles",
                title: "No skills found yet",
                blurb: "Skills are reusable instructions in .claude/skills that Claude loads on demand for specialized tasks.",
                docsURL: "https://code.claude.com/docs/en/skills"
            )
        } else {
            ForEach(unlisted, id: \.self) { name in
                capabilityRow(name: name, detail: "", source: "in use", active: true) {
                    uiModel.openDetail(CapabilityDetail(
                        kind: "Skill",
                        title: name,
                        source: "in use",
                        description: "Invoked this turn. Not in your skill roster — likely bundled with Claude Code or provided by a plugin.",
                        active: true,
                        activeLabel: "in use"
                    ))
                }
            }
            ForEach(skills.filter { isSkillActive($0, in: activeNames) }) { skill in
                capabilityRow(name: skill.name, detail: skill.detail, source: skill.source, active: true) {
                    uiModel.openDetail(skillDetail(skill, active: true))
                }
            }
            if !uiModel.onlyActive {
                ForEach(skills.filter { !isSkillActive($0, in: activeNames) }) { skill in
                    capabilityRow(name: skill.name, detail: skill.detail, source: skill.source, active: false) {
                        uiModel.openDetail(skillDetail(skill, active: false))
                    }
                }
            }
        }
    }

    // MARK: - Hooks

    @ViewBuilder
    private var hookRows: some View {
        let hooks = (appState.capabilities?.hooks ?? []).filter { hook in
            !(appState.settings.hideIslandHooks && hook.command.contains(".claude/island/"))
        }
        if hooks.isEmpty {
            CapabilityEmptyState(
                symbol: "link.circle",
                title: "No hooks found yet",
                blurb: "Hooks run your own commands on Claude Code events — the island's prompt capture is powered by one.",
                docsURL: "https://code.claude.com/docs/en/hooks"
            )
        } else {
            ForEach(hooks) { hook in
                let isIslandHook = hook.command.contains(".claude/island/")
                Button {
                    var fields: [CapabilityDetail.Field] = [.init(label: "Event", value: hook.event)]
                    if let matcher = hook.matcher, !matcher.isEmpty {
                        fields.append(.init(label: "Matcher", value: matcher))
                    }
                    fields.append(.init(
                        label: "Scope",
                        value: SourceBadge.label(isIslandHook ? "island" : hook.source,
                                                 projectName: appState.selectedProjectName)
                    ))
                    uiModel.openDetail(CapabilityDetail(
                        kind: "Hook",
                        title: hook.event + (hook.matcher.map { " · \($0)" } ?? ""),
                        source: isIslandHook ? "island" : hook.source,
                        description: hook.command,
                        monospaced: true,
                        path: hook.sourcePath,
                        fields: fields
                    ))
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(hook.event)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            SourceBadge(source: isIslandHook ? "island" : hook.source,
                                        projectName: appState.selectedProjectName)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(.gray.opacity(0.6))
                        }
                        if let matcher = hook.matcher, !matcher.isEmpty {
                            Text(matcher)
                                .font(.caption)
                                .foregroundColor(.gray)
                                .lineLimit(1)
                        }
                        Text(hook.command)
                            .font(.caption.monospaced())
                            .foregroundColor(.gray)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Subagents

    @ViewBuilder
    private var subagentRows: some View {
        let running = appState.selectedSession?.activeUse.agents ?? []
        let subagents = appState.capabilities?.subagents ?? []
        let runningTypes = Set(running.map(\.type))
        let unlisted = running.filter { agent in !subagents.contains { $0.name == agent.type } }
        if uiModel.onlyActive && running.isEmpty {
            NothingActiveNote()
        } else if subagents.isEmpty && unlisted.isEmpty {
            CapabilityEmptyState(
                symbol: "person.2.circle",
                title: "No subagents found yet",
                blurb: "Subagents are specialized personas in .claude/agents that Claude can delegate focused work to.",
                docsURL: "https://code.claude.com/docs/en/sub-agents"
            )
        } else {
            ForEach(unlisted, id: \.self) { agent in
                capabilityRow(name: agent.type, detail: agent.detail, source: "running", active: true) {
                    uiModel.openDetail(CapabilityDetail(
                        kind: "Subagent",
                        title: agent.type,
                        source: "running",
                        description: agent.detail.isEmpty
                            ? "A built-in agent type currently running for this session."
                            : agent.detail,
                        active: true,
                        activeLabel: "running",
                        fields: [.init(label: "Type", value: agent.type)]
                    ))
                }
            }
            ForEach(subagents.filter { runningTypes.contains($0.name) }) { agent in
                capabilityRow(
                    name: agent.name,
                    detail: running.first { $0.type == agent.name }?.detail ?? agent.detail,
                    source: agent.source,
                    active: true
                ) {
                    uiModel.openDetail(subagentDetail(
                        agent,
                        active: true,
                        task: running.first { $0.type == agent.name }?.detail
                    ))
                }
            }
            if !uiModel.onlyActive {
                ForEach(subagents.filter { !runningTypes.contains($0.name) }) { agent in
                    capabilityRow(name: agent.name, detail: agent.detail, source: agent.source, active: false) {
                        uiModel.openDetail(subagentDetail(agent, active: false, task: nil))
                    }
                }
            }
        }
    }

    // MARK: - Shared row / detail builders

    private func capabilityRow(
        name: String,
        detail: String,
        source: String,
        active: Bool,
        open: (() -> Void)? = nil
    ) -> some View {
        let row = VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if active {
                    StatusDot(
                        color: appState.colors.active,
                        pulsing: true,
                        symbol: appState.symbolsEnabled ? "bolt.fill" : nil
                    )
                }
                Text(name)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                SourceBadge(source: source, projectName: appState.selectedProjectName)
                if open != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.gray.opacity(0.6))
                }
            }
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .lineLimit(2)
            }
        }
        return Group {
            if let open {
                Button(action: open) {
                    row.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                row
            }
        }
    }

    private func skillDetail(_ skill: SkillInfo, active: Bool) -> CapabilityDetail {
        CapabilityDetail(
            kind: "Skill",
            title: skill.name,
            source: skill.source,
            description: skill.detail.isEmpty ? "No description in SKILL.md frontmatter." : skill.detail,
            active: active,
            activeLabel: "in use",
            path: skill.path
        )
    }

    private func subagentDetail(_ agent: SubagentInfo, active: Bool, task: String?) -> CapabilityDetail {
        var fields: [CapabilityDetail.Field] = []
        if let task, !task.isEmpty, task != agent.detail {
            fields.append(.init(label: "Task", value: task))
        }
        return CapabilityDetail(
            kind: "Subagent",
            title: agent.name,
            source: agent.source,
            description: agent.detail.isEmpty ? "No description in the agent's frontmatter." : agent.detail,
            active: active,
            activeLabel: "running",
            path: agent.path,
            fields: fields
        )
    }
}
