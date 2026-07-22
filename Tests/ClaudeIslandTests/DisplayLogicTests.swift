import XCTest
@testable import ClaudeIsland

@MainActor
final class DisplayLogicTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "island-display-tests-\(UUID().uuidString)"
    private var settings: AppSettings!
    private var state: AppState!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)
        settings = AppSettings(defaults: defaults)
        state = AppState(settings: settings)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    private func snapshot(
        percentLeft: Double = 63,
        unlimited: Bool = false,
        dollarsUsed: Double? = nil,
        dollarsBudget: Double? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            percentLeft: percentLeft, usedDisplay: "u", budgetDisplay: "b",
            windowLabel: "Weekly · Fable", sourceLabel: "s", resetsAt: nil,
            updatedAt: Date(), officialLimits: [], isUnlimited: unlimited,
            dollarsUsed: dollarsUsed, dollarsBudget: dollarsBudget
        )
    }

    // MARK: - Percent text matrix

    func testPercentLeftAndUsed() {
        state.snapshot = snapshot(percentLeft: 63)
        settings.percentDisplay = .left
        XCTAssertEqual(state.percentLeftText, "63%")
        settings.percentDisplay = .used
        XCTAssertEqual(state.percentLeftText, "37%")
    }

    func testNoSnapshotShowsDash() {
        XCTAssertEqual(state.percentLeftText, "–")
    }

    func testUnlimitedShowsInfinityInPercentMode() {
        state.snapshot = snapshot(unlimited: true, dollarsUsed: 142.10)
        settings.displayUnit = .percent
        XCTAssertEqual(state.percentLeftText, "∞")
    }

    func testDollarModeShowsSpendAndBalance() {
        state.snapshot = snapshot(dollarsUsed: 12.34, dollarsBudget: 35)
        settings.displayUnit = .dollars
        settings.percentDisplay = .used
        XCTAssertEqual(state.percentLeftText, "$12.34")
        settings.percentDisplay = .left
        XCTAssertEqual(state.percentLeftText, "$22.66")
    }

    func testDollarBalanceWithoutBudgetFallsBackToSpend() {
        state.snapshot = snapshot(unlimited: true, dollarsUsed: 142.10, dollarsBudget: nil)
        settings.displayUnit = .dollars
        settings.percentDisplay = .left
        XCTAssertEqual(state.percentLeftText, "$142", "compactDollars drops cents past $100")
    }

    func testCompactDollars() {
        XCTAssertEqual(Format.compactDollars(12.34), "$12.34")
        XCTAssertEqual(Format.compactDollars(123.4), "$123")
        XCTAssertEqual(Format.compactDollars(1234), "$1.2K")
    }

    func testDescriptionsNameTheLimit() {
        state.snapshot = snapshot(percentLeft: 55)
        settings.percentDisplay = .used
        XCTAssertTrue(state.percentDescription.contains("45%"))
        XCTAssertTrue(state.percentDescription.contains("Weekly · Fable"))
    }

    func testHeadlineHonorsUnlimitedAndUnit() {
        state.snapshot = snapshot(unlimited: true, dollarsUsed: 142.10)
        settings.displayUnit = .dollars
        XCTAssertEqual(state.summary.headline.number, "$142")
        XCTAssertEqual(state.summary.headline.suffix, "spent · unlimited")
        settings.displayUnit = .percent
        XCTAssertEqual(state.summary.headline.number, "∞")
        XCTAssertEqual(state.summary.headline.suffix, "unlimited")
        state.snapshot = snapshot(percentLeft: 63)
        XCTAssertEqual(state.summary.headline.number, "63%")
        XCTAssertEqual(state.summary.headline.suffix, "left")
    }

    // MARK: - Session status parsing

    func testSessionStatusParsing() {
        XCTAssertEqual(SessionStatus(raw: "busy"), .busy)
        XCTAssertEqual(SessionStatus(raw: "Working"), .busy)
        XCTAssertEqual(SessionStatus(raw: "running"), .busy)
        XCTAssertEqual(SessionStatus(raw: "WAITING"), .waiting)
        XCTAssertEqual(SessionStatus(raw: "idle"), .idle)
        XCTAssertEqual(SessionStatus(raw: "compacting"), .other("compacting"),
                       "unknown statuses degrade gracefully instead of failing")
    }

    // MARK: - Accessibility plumbing

    func testPaletteFollowsColorVision() {
        settings.colorVision = .standard
        XCTAssertEqual(state.colors.working, SemanticColors.standard.working)
        settings.colorVision = .tritanopia
        XCTAssertEqual(state.colors.working, SemanticColors.tritanopia.working)
    }

    func testMonochromeForcesSymbols() {
        settings.statusSymbols = false
        settings.colorVision = .monochrome
        XCTAssertTrue(state.symbolsEnabled)
        settings.colorVision = .standard
        XCTAssertFalse(state.symbolsEnabled)
        settings.statusSymbols = true
        XCTAssertTrue(state.symbolsEnabled)
    }

    func testEveryVisionTypeHasAPalette() {
        for vision in ColorVision.allCases {
            settings.colorVision = vision
            _ = state.colors // must not trap; distinctness spot-checked below
        }
        XCTAssertNotEqual(SemanticColors.deuteranopia.working, SemanticColors.deuteranopia.waiting)
        XCTAssertNotEqual(SemanticColors.tritanopia.working, SemanticColors.tritanopia.low)
    }

    // MARK: - Session model helpers

    func testContextPercentPrefersReportedValue() {
        var session = sessionFixture()
        session.contextTokens = 500_000
        session.contextLimit = 1_000_000
        XCTAssertEqual(session.contextPercent, 50)
        session.reportedContextPercent = 57.4
        XCTAssertEqual(session.contextPercent, 57)
    }

    func testModelShortNames() {
        var session = sessionFixture()
        for (id, expected) in [
            ("claude-fable-5", "Fable"), ("Fable 5", "Fable"),
            ("Opus 4.8 (1M context)", "Opus"), ("claude-sonnet-5", "Sonnet"),
            ("claude-haiku-4-5", "Haiku"),
        ] {
            session.model = id
            XCTAssertEqual(session.modelShortName, expected, "for \(id)")
        }
    }

    func testAttentionSessionPrefersSelection() {
        let a = sessionFixture(id: "a", status: "waiting")
        let b = sessionFixture(id: "b", status: "waiting")
        state.sessions = [a, b]
        state.selectedSessionIndex = 1
        XCTAssertEqual(state.attentionSession?.id, "b")
        state.selectedSessionIndex = 0
        XCTAssertEqual(state.attentionSession?.id, "a")
    }

    func testNeedsAttentionHasNoFreshnessDecay() {
        let stale = sessionFixture(status: "waiting", updatedAt: Date(timeIntervalSinceNow: -3600))
        XCTAssertTrue(stale.needsAttention, "an open prompt stays open however long the user is away")
    }

    func testActivelyWorkingRequiresFreshTranscript() {
        let fresh = sessionFixture(status: "busy", transcriptActivityAt: Date(timeIntervalSinceNow: -10))
        XCTAssertTrue(fresh.isActivelyWorking)
        let stale = sessionFixture(status: "busy", transcriptActivityAt: Date(timeIntervalSinceNow: -600))
        XCTAssertFalse(stale.isActivelyWorking)
        XCTAssertTrue(stale.displayStatus.contains("stale"))
    }

    private func sessionFixture(
        id: String = "s", status: String = "idle", updatedAt: Date = Date(),
        transcriptActivityAt: Date? = nil
    ) -> SessionInfo {
        SessionInfo(
            id: id, name: id, cwd: "/tmp/x", status: status, pid: 1,
            version: nil, updatedAt: updatedAt, statusUpdatedAt: nil,
            transcriptActivityAt: transcriptActivityAt, pendingPrompt: nil
        )
    }
}
