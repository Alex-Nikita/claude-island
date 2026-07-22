import XCTest
@testable import ClaudeIsland

final class AnswerFlowTests: XCTestCase {
    private var flow = AnswerFlow()

    override func setUp() {
        flow = AnswerFlow()
    }

    // MARK: - Fixtures

    private func prompt(_ questions: [PromptQuestion]) -> PendingPrompt {
        PendingPrompt(toolName: "AskUserQuestion", title: questions.first?.header ?? "",
                      detail: questions.first?.question ?? "",
                      options: questions.first?.options ?? [],
                      answerable: true, allQuestions: questions)
    }

    private func single(_ question: String = "Pick?", options: [String] = ["A", "B"],
                        multi: Bool = false) -> PromptQuestion {
        PromptQuestion(question: question, header: "H-\(question)", options: options,
                       isMultiSelect: multi)
    }

    private var threeStep: PendingPrompt {
        prompt([
            single("Q1?"),
            single("Q2?", options: ["X", "Y", "Z"], multi: true),
            single("Q3?", options: ["Yes", "No"]),
        ])
    }

    // MARK: - Single question

    func testSingleQuestionCommitSendsImmediately() {
        let sent = flow.commit("A", prompt: prompt([single()]))
        XCTAssertEqual(sent?.count, 1)
        XCTAssertEqual(sent?[0].question, "Pick?")
        XCTAssertEqual(sent?[0].value, "A")
        XCTAssertTrue(flow.answersSent)
    }

    func testFreeTextValueNeedNotMatchAnOption() {
        let sent = flow.commit("my own words", prompt: prompt([single()]))
        XCTAssertEqual(sent?[0].value, "my own words")
    }

    func testCommitAfterSentIsIgnored() {
        let p = prompt([single()])
        _ = flow.commit("A", prompt: p)
        XCTAssertNil(flow.commit("B", prompt: p), "a sent flow is frozen")
    }

    // MARK: - Multi-question stepping

    func testAdvancesThroughQuestionsAndSendsOrdered() {
        let p = threeStep
        XCTAssertNil(flow.commit("A", prompt: p))
        XCTAssertEqual(flow.questionIndex, 1)
        XCTAssertNil(flow.commit("X", prompt: p))
        XCTAssertEqual(flow.questionIndex, 2)
        let sent = flow.commit("Yes", prompt: p)
        XCTAssertEqual(sent?.map(\.value), ["A", "X", "Yes"])
        XCTAssertEqual(sent?.map(\.question), ["Q1?", "Q2?", "Q3?"])
        XCTAssertTrue(flow.answersSent)
    }

    func testSendOnlyFiresOnTheCompletingCommit() {
        let p = threeStep
        XCTAssertNil(flow.commit("A", prompt: p), "1 of 3 answered — no send")
        XCTAssertNil(flow.commit("X", prompt: p), "2 of 3 answered — no send")
        XCTAssertFalse(flow.answersSent)
    }

    // MARK: - Combined multi-select

    func testCommitMultiJoinsChecksInDisplayOrderPlusTypedText() {
        let p = threeStep
        _ = flow.commit("A", prompt: p)          // now on the multi-select Q2
        flow.selectedLabels = ["Z", "X"]         // toggled out of display order
        flow.freeTextDraft = "  typed extra  "
        XCTAssertNil(flow.commitMulti(prompt: p))
        // Display order X, Z — not toggle order — then the trimmed typed text.
        XCTAssertEqual(flow.answersByIndex[1], "X, Z, typed extra")
    }

    func testCommitMultiWithOnlyTypedText() {
        let p = threeStep
        _ = flow.commit("A", prompt: p)
        flow.freeTextDraft = "just typing"
        XCTAssertNil(flow.commitMulti(prompt: p))
        XCTAssertEqual(flow.answersByIndex[1], "just typing")
    }

    func testCommitMultiRefusesEmptyAnswer() {
        let p = threeStep
        _ = flow.commit("A", prompt: p)
        flow.freeTextDraft = "   "
        XCTAssertNil(flow.commitMulti(prompt: p))
        XCTAssertNil(flow.answersByIndex[1], "whitespace-only must not count as an answer")
        XCTAssertTrue(flow.multiAnswerIsEmpty)
    }

    // MARK: - Navigation

    func testFrontierRuleForbidsSkippingAhead() {
        let p = threeStep
        XCTAssertTrue(flow.canVisit(0, prompt: p), "the frontier itself is visitable")
        XCTAssertFalse(flow.canVisit(1, prompt: p), "cannot skip past an unanswered question")
        XCTAssertFalse(flow.canVisit(2, prompt: p))
        _ = flow.commit("A", prompt: p)
        XCTAssertTrue(flow.canVisit(0, prompt: p), "answered questions stay visitable")
        XCTAssertTrue(flow.canVisit(1, prompt: p))
        XCTAssertFalse(flow.canVisit(2, prompt: p))
        XCTAssertFalse(flow.canVisit(3, prompt: p), "out of range")
        XCTAssertFalse(flow.canVisit(-1, prompt: p))
    }

    func testGoBackRestoresHowTheAnswerWasComposed() {
        let p = threeStep
        _ = flow.commit("A", prompt: p)
        flow.selectedLabels = ["Y"]
        flow.freeTextDraft = "note"
        _ = flow.commitMulti(prompt: p)          // Q2 answered, now on Q3
        flow.goTo(1, prompt: p)
        XCTAssertEqual(flow.questionIndex, 1)
        XCTAssertEqual(flow.selectedLabels, ["Y"], "checks restored")
        XCTAssertEqual(flow.freeTextDraft, "note", "draft restored")
        XCTAssertTrue(flow.freeTextActive, "a restored draft opens the field")
        flow.goTo(0, prompt: p)
        XCTAssertEqual(flow.selectedLabels, ["A"], "single-select restores its pick as selection")
    }

    func testInFlightStateSurvivesTheRoundTrip() {
        let p = threeStep
        _ = flow.commit("A", prompt: p)
        // Toggle on Q2 WITHOUT committing, wander off, come back.
        flow.selectedLabels = ["X"]
        flow.freeTextDraft = "half-typed"
        flow.goTo(0, prompt: p)
        XCTAssertEqual(flow.selectedLabels, ["A"])
        flow.goTo(1, prompt: p)
        XCTAssertEqual(flow.selectedLabels, ["X"], "uncommitted toggles survive")
        XCTAssertEqual(flow.freeTextDraft, "half-typed")
    }

    func testRevisingAnAnswerReplacesItAndAdvancesToFrontier() {
        let p = threeStep
        _ = flow.commit("A", prompt: p)
        _ = flow.commit("X", prompt: p)          // on Q3 now
        flow.goTo(0, prompt: p)
        XCTAssertNil(flow.commit("free text instead", prompt: p))
        XCTAssertEqual(flow.answersByIndex[0], "free text instead")
        XCTAssertEqual(flow.questionIndex, 2, "revision hops to the first unanswered question")
        let sent = flow.commit("No", prompt: p)
        XCTAssertEqual(sent?.map(\.value), ["free text instead", "X", "No"])
    }

    func testRevisingTheLastGapSends() {
        let p = threeStep
        _ = flow.commit("A", prompt: p)
        _ = flow.commit("X", prompt: p)
        flow.goTo(1, prompt: p)                  // revisit answered Q2, leaving Q3 open
        XCTAssertNil(flow.commit("Y", prompt: p))
        XCTAssertEqual(flow.questionIndex, 2, "forward to the still-open question")
        XCTAssertNotNil(flow.commit("Yes", prompt: p))
    }

    func testGoToRejectsUnreachableAndSelf() {
        let p = threeStep
        flow.goTo(2, prompt: p)
        XCTAssertEqual(flow.questionIndex, 0, "cannot jump past the frontier")
        flow.goTo(0, prompt: p)
        XCTAssertEqual(flow.questionIndex, 0)
    }

    func testNavigationFrozenAfterSend() {
        let p = prompt([single("Q1?"), single("Q2?")])
        _ = flow.commit("A", prompt: p)
        _ = flow.commit("A", prompt: p)
        XCTAssertTrue(flow.answersSent)
        XCTAssertFalse(flow.canVisit(0, prompt: p))
        flow.goTo(0, prompt: p)
        XCTAssertEqual(flow.questionIndex, 1, "no navigation after the answers went out")
    }

    // MARK: - Reset

    func testResetClearsEverything() {
        let p = threeStep
        _ = flow.commit("A", prompt: p)
        flow.selectedLabels = ["X"]
        flow.freeTextDraft = "draft"
        flow.reset()
        XCTAssertEqual(flow.questionIndex, 0)
        XCTAssertTrue(flow.answersByIndex.isEmpty)
        XCTAssertTrue(flow.selectedLabels.isEmpty)
        XCTAssertEqual(flow.freeTextDraft, "")
        XCTAssertFalse(flow.answersSent)
    }

    // MARK: - Degenerate input

    func testEmptyPromptDoesNothing() {
        let p = prompt([])
        XCTAssertNil(flow.currentQuestion(of: p))
        XCTAssertNil(flow.commit("A", prompt: p))
        XCTAssertFalse(flow.canVisit(0, prompt: p))
        XCTAssertFalse(flow.answersSent)
    }
}
