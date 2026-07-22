import Foundation

/// The multi-question answer state machine behind the island's question page.
/// Pure value type so the wizard rules — frontier navigation, per-question
/// state restore, combined multi-select answers, send-when-complete — are
/// unit-testable without SwiftUI.
struct AnswerFlow {
    private(set) var questionIndex = 0
    // Keyed by question index so answers survive back-and-forth navigation
    // and can be revised until the final send.
    private(set) var answersByIndex: [Int: String] = [:]
    private(set) var savedLabels: [Int: Set<String>] = [:]
    private(set) var savedDrafts: [Int: String] = [:]
    private(set) var answersSent = false
    var selectedLabels: Set<String> = []
    var freeTextDraft = ""
    var freeTextActive = false

    mutating func reset() {
        self = AnswerFlow()
    }

    func currentQuestion(of prompt: PendingPrompt) -> PromptQuestion? {
        guard !prompt.allQuestions.isEmpty else { return nil }
        return prompt.allQuestions[min(questionIndex, prompt.allQuestions.count - 1)]
    }

    var multiAnswerIsEmpty: Bool {
        selectedLabels.isEmpty
            && freeTextDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // A step is reachable when it was already answered/visited, or it is the
    // first unanswered one — no skipping ahead past unanswered questions.
    func canVisit(_ index: Int, prompt: PendingPrompt) -> Bool {
        guard index >= 0, index < prompt.allQuestions.count, !answersSent else { return false }
        if answersByIndex[index] != nil || savedLabels[index] != nil { return true }
        let frontier = (0..<prompt.allQuestions.count).first { answersByIndex[$0] == nil }
        return index == frontier
    }

    // Jump to another step, keeping whatever was selected or typed on both
    // sides so nothing is lost while hopping around.
    mutating func goTo(_ index: Int, prompt: PendingPrompt) {
        guard index != questionIndex, canVisit(index, prompt: prompt) else { return }
        savedLabels[questionIndex] = selectedLabels
        savedDrafts[questionIndex] = freeTextDraft
        questionIndex = index
        restoreState(for: index)
    }

    /// Records the current question's value and advances to the next
    /// unanswered question. Returns the full ordered answer list exactly once
    /// — on the commit that completes the set — after which the flow is sent
    /// and frozen; nil otherwise.
    mutating func commit(_ value: String, prompt: PendingPrompt)
        -> [(question: String, value: String)]? {
        guard !answersSent, let current = currentQuestion(of: prompt) else { return nil }
        answersByIndex[questionIndex] = value
        // Remember how the answer was composed so revisiting restores it.
        if current.isMultiSelect {
            savedLabels[questionIndex] = selectedLabels
            savedDrafts[questionIndex] = freeTextDraft
        } else {
            let isOption = current.options.contains(value)
            savedLabels[questionIndex] = isOption ? [value] : []
            savedDrafts[questionIndex] = isOption ? "" : value
        }
        let count = prompt.allQuestions.count
        if answersByIndex.count == count {
            answersSent = true
            return (0..<count).map {
                (question: prompt.allQuestions[$0].question, value: answersByIndex[$0] ?? "")
            }
        }
        if let next = ((questionIndex + 1)..<count).first(where: { answersByIndex[$0] == nil })
            ?? (0..<count).first(where: { answersByIndex[$0] == nil }) {
            questionIndex = next
            restoreState(for: next)
        }
        return nil
    }

    /// Multi-select submits ONE combined answer: checked options in display
    /// order, plus whatever was typed, joined like the terminal dialog would.
    mutating func commitMulti(prompt: PendingPrompt) -> [(question: String, value: String)]? {
        var picked = (currentQuestion(of: prompt)?.options ?? []).filter { selectedLabels.contains($0) }
        let typed = freeTextDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { picked.append(typed) }
        guard !picked.isEmpty else { return nil }
        return commit(picked.joined(separator: ", "), prompt: prompt)
    }

    private mutating func restoreState(for index: Int) {
        selectedLabels = savedLabels[index] ?? []
        freeTextDraft = savedDrafts[index] ?? ""
        freeTextActive = !(savedDrafts[index] ?? "").isEmpty
    }
}
