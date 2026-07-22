import XCTest
@testable import ClaudeIsland

final class UsageEngineTests: XCTestCase {
    private var home: FixtureHome!
    private let engine = UsageEngine()

    override func setUpWithError() throws {
        home = try FixtureHome()
    }

    override func tearDown() {
        home.tearDown()
        home = nil
    }

    private func query(
        source: UsageSource = .officialAPI,
        window: UsageWindow = .fiveHour,
        mode: SettingsMode = .detected,
        wantDollars: Bool = false,
        preferredLimitID: String? = nil
    ) -> UsageQuery {
        UsageQuery(
            source: source, window: window, costMultiplier: 1,
            costBudget: 35, tokenBudget: 50_000_000, weightCacheTokens: true,
            mode: mode, wantDollarStats: wantDollars, preferredLimitID: preferredLimitID
        )
    }

    private func limit(_ kind: String, _ label: String, _ percent: Double,
                       active: Bool = false) -> OfficialLimit {
        OfficialLimit(kind: kind, label: label, percentUsed: percent,
                      severity: "normal", resetsAt: nil, isActive: active)
    }

    // MARK: - Detected mode / binding limit

    func testDetectedModeHeadlinesTightestLimit() {
        let usage = OfficialUsage(
            fiveHourUtilization: 8, fiveHourResetsAt: nil,
            sevenDayUtilization: 27, sevenDayResetsAt: nil,
            limits: [
                limit("session", "Session", 8),
                limit("weekly_all", "Weekly (all models)", 27),
                limit("weekly_scoped", "Weekly · Fable", 45, active: true),
            ]
        )
        let snap = engine.officialSnapshot(usage: usage, query: query())
        XCTAssertEqual(snap?.percentLeft, 55)
        XCTAssertEqual(snap?.windowLabel, "Weekly · Fable")
        XCTAssertEqual(snap?.officialLimits.count, 3)
        XCTAssertTrue(snap?.sourceLabel.contains("tightest") ?? false)
    }

    func testActiveFlagOutranksRawPercent() {
        // is_active limits win even when an inactive one shows higher percent.
        let usage = OfficialUsage(
            fiveHourUtilization: nil, fiveHourResetsAt: nil,
            sevenDayUtilization: nil, sevenDayResetsAt: nil,
            limits: [
                limit("session", "Session", 90),
                limit("weekly_all", "Weekly (all models)", 45, active: true),
            ]
        )
        let snap = engine.officialSnapshot(usage: usage, query: query())
        XCTAssertEqual(snap?.windowLabel, "Weekly (all models)")
    }

    func testPinnedLimitOverridesTightest() {
        let session = limit("session", "Session", 8)
        let usage = OfficialUsage(
            fiveHourUtilization: nil, fiveHourResetsAt: nil,
            sevenDayUtilization: nil, sevenDayResetsAt: nil,
            limits: [session, limit("weekly_scoped", "Weekly · Fable", 45, active: true)]
        )
        let snap = engine.officialSnapshot(
            usage: usage, query: query(preferredLimitID: session.id)
        )
        XCTAssertEqual(snap?.windowLabel, "Session")
        XCTAssertEqual(snap?.percentLeft, 92)
        XCTAssertTrue(snap?.sourceLabel.contains("pinned") ?? false)
    }

    func testVanishedPinFallsBackToTightest() {
        let usage = OfficialUsage(
            fiveHourUtilization: nil, fiveHourResetsAt: nil,
            sevenDayUtilization: nil, sevenDayResetsAt: nil,
            limits: [limit("weekly_all", "Weekly (all models)", 30)]
        )
        let snap = engine.officialSnapshot(
            usage: usage, query: query(preferredLimitID: "gone|Gone")
        )
        XCTAssertEqual(snap?.windowLabel, "Weekly (all models)")
        XCTAssertTrue(snap?.sourceLabel.contains("tightest") ?? false)
    }

    // MARK: - Custom mode windows

    func testCustomModeUsesSelectedWindow() {
        let usage = OfficialUsage(
            fiveHourUtilization: 8, fiveHourResetsAt: nil,
            sevenDayUtilization: 27, sevenDayResetsAt: nil,
            limits: [limit("weekly_scoped", "Weekly · Fable", 45, active: true)]
        )
        let snap = engine.officialSnapshot(usage: usage, query: query(window: .fiveHour, mode: .custom))
        XCTAssertEqual(snap?.percentLeft, 92)
        XCTAssertEqual(snap?.windowLabel, "5-hour")
    }

    // MARK: - Credit accounts

    func testCreditLimitedAccount() {
        let usage = OfficialUsage(
            fiveHourUtilization: nil, fiveHourResetsAt: nil,
            sevenDayUtilization: nil, sevenDayResetsAt: nil,
            limits: [],
            fiveHourDollars: DollarUsage(used: 12.34, limit: 50, resetsAt: nil)
        )
        let snap = engine.officialSnapshot(usage: usage, query: query(mode: .custom))
        XCTAssertEqual(snap?.percentLeft ?? 0, 75.32, accuracy: 0.01)
        XCTAssertEqual(snap?.usedDisplay, "$12.34")
        XCTAssertTrue(snap?.budgetDisplay.contains("credits") ?? false)
        XCTAssertEqual(snap?.dollarsUsed, 12.34)
        XCTAssertEqual(snap?.dollarsBudget, 50)
    }

    func testCrossWindowCreditFallback() {
        // Cap only on weekly while 5-hour is selected: show weekly, not failure.
        let usage = OfficialUsage(
            fiveHourUtilization: nil, fiveHourResetsAt: nil,
            sevenDayUtilization: nil, sevenDayResetsAt: nil,
            limits: [],
            sevenDayDollars: DollarUsage(used: 80.5, limit: 250, resetsAt: nil)
        )
        let snap = engine.officialSnapshot(usage: usage, query: query(window: .fiveHour, mode: .custom))
        XCTAssertEqual(snap?.windowLabel, "Weekly")
        XCTAssertEqual(snap?.percentLeft ?? 0, 67.8, accuracy: 0.01)
    }

    // MARK: - Unlimited

    func testUnlimitedAccountSnapshot() {
        let usage = OfficialUsage(
            fiveHourUtilization: nil, fiveHourResetsAt: nil,
            sevenDayUtilization: nil, sevenDayResetsAt: nil,
            limits: [],
            sevenDayDollars: DollarUsage(used: 142.10, limit: nil, resetsAt: nil)
        )
        for mode in [SettingsMode.detected, .custom] {
            let snap = engine.officialSnapshot(usage: usage, query: query(mode: mode))
            XCTAssertEqual(snap?.isUnlimited, true)
            XCTAssertEqual(snap?.percentLeft, 100)
            XCTAssertEqual(snap?.budgetDisplay, "unlimited")
            XCTAssertEqual(snap?.dollarsUsed, 142.10)
            XCTAssertNil(snap?.dollarsBudget ?? nil)
        }
    }

    // MARK: - Local estimates via fixture transcripts

    private func writeUsageTranscript() throws {
        // One assistant entry with a usage block inside the current window.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line: [String: Any] = [
            "type": "assistant",
            "timestamp": formatter.string(from: Date()),
            "requestId": "req_1",
            "message": [
                "id": "msg_1", "model": "claude-fable-5", "role": "assistant", "content": [],
                "usage": [
                    "input_tokens": 1_000_000, "output_tokens": 100_000,
                    "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0,
                ],
            ],
        ]
        _ = try home.writeLines(".claude/projects/-proj/abc.jsonl", [line])
    }

    func testTokenCountSnapshotFromFixture() async throws {
        try writeUsageTranscript()
        let snap = await engine.computeSnapshot(query: query(source: .tokenCounts, mode: .custom))
        // 1.1M weighted tokens of a 50M budget.
        XCTAssertEqual(snap.percentLeft, 97.8, accuracy: 0.1)
        XCTAssertTrue(snap.usedDisplay.contains("wtd"))
        // Dollar stats ride along: 1M in @$10 + 0.1M out @$50 = $15.
        XCTAssertEqual(snap.dollarsUsed ?? 0, 15, accuracy: 0.01)
    }

    func testMonthlyWindowSnapshot() async throws {
        try writeUsageTranscript()
        let snap = await engine.computeSnapshot(
            query: query(source: .costEstimate, window: .monthly, mode: .custom)
        )
        XCTAssertEqual(snap.windowLabel, "Calendar month")
        XCTAssertNotNil(snap.resetsAt, "monthly snapshots carry the next-month reset")
        XCTAssertEqual(snap.usedDisplay, "$15.00")
    }

    func testScanFailureFallsBackGracefully() async {
        // No projects dir at all.
        let snap = await engine.computeSnapshot(query: query(source: .tokenCounts, mode: .custom))
        XCTAssertEqual(snap.percentLeft, 100)
        // A missing projects dir scans as zero usage, not an error.
        XCTAssertTrue(["no data", "0 wtd"].contains(snap.usedDisplay))
    }

    // MARK: - Formatting

    func testFormatTokens() {
        XCTAssertEqual(Format.tokens(999), "999")
        XCTAssertEqual(Format.tokens(8_200_000), "8.2M")
        XCTAssertEqual(Format.tokens(1_000_000_000), "1B")
        XCTAssertEqual(Format.tokens(50_000), "50K")
    }

    func testFormatDollars() {
        XCTAssertEqual(Format.dollars(12.345), "$12.35")
        XCTAssertEqual(Format.dollars(0), "$0.00")
    }
}
