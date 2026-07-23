import XCTest
@testable import ClaudeIsland

@MainActor
final class AppSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "island-tests-\(UUID().uuidString)"

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    private func fresh() -> AppSettings { AppSettings(defaults: defaults) }

    // MARK: - Defaults

    func testFactoryDefaults() {
        let s = fresh()
        XCTAssertEqual(s.mode, .detected)
        XCTAssertFalse(s.connectAccount, "keychain access must be opt-in")
        XCTAssertEqual(s.displayUnit, .percent)
        XCTAssertEqual(s.percentDisplay, .left)
        XCTAssertEqual(s.colorVision, .standard)
        XCTAssertTrue(s.hideIslandHooks)
        XCTAssertNil(s.selectedLimitID)
        XCTAssertTrue(s.autoExpandOnPrompt, "matches the pre-toggle built-in behavior")
        XCTAssertTrue(s.collapseOnClickAway, "matches the pre-toggle built-in behavior")
    }

    // MARK: - Persistence round-trip

    func testPersistenceRoundTrip() {
        let s = fresh()
        s.mode = .custom
        s.displayUnit = .dollars
        s.percentDisplay = .used
        s.colorVision = .tritanopia
        s.selectedLimitID = "weekly_scoped|Weekly · Fable"
        s.customCostBudgetMonthly = 777
        s.autoExpandOnPrompt = false
        s.collapseOnClickAway = false

        let reloaded = fresh()
        XCTAssertEqual(reloaded.mode, .custom)
        XCTAssertEqual(reloaded.displayUnit, .dollars)
        XCTAssertEqual(reloaded.percentDisplay, .used)
        XCTAssertEqual(reloaded.colorVision, .tritanopia)
        XCTAssertEqual(reloaded.selectedLimitID, "weekly_scoped|Weekly · Fable")
        XCTAssertEqual(reloaded.customCostBudgetMonthly, 777)
        XCTAssertFalse(reloaded.autoExpandOnPrompt)
        XCTAssertFalse(reloaded.collapseOnClickAway)
    }

    func testClearingSelectedLimitPersistsAsNil() {
        let s = fresh()
        s.selectedLimitID = "x"
        s.selectedLimitID = nil
        XCTAssertNil(fresh().selectedLimitID)
    }

    func testConnectWithoutBuildBlessingSelfHeals() {
        // "Connected" with no recorded blessing is an inconsistent state —
        // it must fall back to the plain Connect flow, not claim a
        // connection that has no grant behind it.
        defaults.set(true, forKey: "claudeIsland.connectAccount")
        XCTAssertFalse(fresh().connectAccount)
        XCTAssertFalse(fresh().connectAccount, "the heal persists")

        defaults.set(true, forKey: "claudeIsland.connectAccount")
        defaults.set("deadbeef", forKey: "claudeIsland.authorizedBuildHash")
        XCTAssertTrue(fresh().connectAccount, "a blessed connection survives")
    }

    func testNotchModeToggleRoutesThroughDisplayMode() {
        let s = fresh()
        s.notchModeEnabled = true
        XCTAssertEqual(s.displayMode, .notch)
        XCTAssertTrue(fresh().notchModeEnabled, "persists via the displayMode key")
        s.notchModeEnabled = false
        XCTAssertEqual(s.displayMode, .pill)
    }

    // MARK: - Migration

    func testColorBlindBooleanMigratesToDeuteranopia() {
        defaults.set(true, forKey: "claudeIsland.colorBlindPalette")
        XCTAssertEqual(fresh().colorVision, .deuteranopia)
    }

    func testTypedColorVisionBeatsLegacyBoolean() {
        defaults.set(true, forKey: "claudeIsland.colorBlindPalette")
        defaults.set("tritanopia", forKey: "claudeIsland.colorVision")
        XCTAssertEqual(fresh().colorVision, .tritanopia)
    }

    func testUsageBasedAccountKindMigratesToCostMonthly() {
        // The old Custom "Usage-based" account kind is gone — it becomes
        // Measure = Cost over a Monthly window, and the stale key is cleared.
        defaults.set("usageBased", forKey: "claudeIsland.accountKind")
        let s = fresh()
        XCTAssertEqual(s.source, .costEstimate)
        XCTAssertEqual(s.window, .monthly)
        XCTAssertNil(defaults.string(forKey: "claudeIsland.accountKind"), "stale key cleared")
    }

    // MARK: - Budgets

    func testPresetBudgets() {
        let s = fresh()
        s.mode = .custom
        s.planPreset = .max20x
        XCTAssertEqual(s.tokenBudget(for: .fiveHour), 200_000_000)
        XCTAssertEqual(s.costBudget(for: .weekly), 1200)
    }

    func testMonthlyBudgetIgnoresPresets() {
        let s = fresh()
        s.planPreset = .pro
        s.customCostBudgetMonthly = 555
        XCTAssertEqual(s.costBudget(for: .monthly), 555)
    }

    func testDetectedPlanOverridesManualPreset() {
        let s = fresh()
        s.mode = .detected
        s.planPreset = .pro
        s.detectedPlanPreset = .max20x
        XCTAssertEqual(s.effectivePlanPreset, .max20x)
        s.mode = .custom
        XCTAssertEqual(s.effectivePlanPreset, .pro)
    }

    // MARK: - Query derivation

    func testDetectedModeWithoutConsentUsesLocalEstimates() {
        let s = fresh()
        s.mode = .detected
        s.connectAccount = false
        XCTAssertEqual(s.makeQuery().source, .tokenCounts)
    }

    func testDetectedModeWithConsentUsesOfficialAPI() {
        let s = fresh()
        s.mode = .detected
        s.connectAccount = true
        let q = s.makeQuery()
        XCTAssertEqual(q.source, .officialAPI)
        XCTAssertEqual(q.mode, .detected)
    }

    func testClaudeAccountModeLabelAndRawValue() {
        // The mode shown as "Claude account" is still the .detected case under
        // the hood — the label changed, the stored rawValue must not, or every
        // existing user's persisted mode would silently reset.
        XCTAssertEqual(SettingsMode.detected.title, "Claude account")
        XCTAssertEqual(SettingsMode.detected.rawValue, "detected")
    }

    func testOfficialAPISourceMigratesToTokenCounts() {
        // A persisted Custom "Official API" selection from before the source
        // list dropped it must load as a valid local source (the live path now
        // lives only in Claude-account mode), not leave the radio group blank.
        defaults.set("officialAPI", forKey: "claudeIsland.source")
        let s = fresh()
        XCTAssertEqual(s.source, .tokenCounts)
        XCTAssertEqual(defaults.string(forKey: "claudeIsland.source"), "tokenCounts",
                       "migration is written back, not just masked in memory")
    }

    func testCustomMonthlyCostQuery() {
        let s = fresh()
        s.mode = .custom
        s.source = .costEstimate
        s.window = .monthly
        s.customCostBudgetMonthly = 900
        let q = s.makeQuery()
        XCTAssertEqual(q.source, .costEstimate)
        XCTAssertEqual(q.window, .monthly)
        XCTAssertEqual(q.costBudget, 900)
    }

    func testCustomMonthlyTokenQuery() {
        // Measure now applies to Monthly too — tokens over a calendar month,
        // which the old account-kind model couldn't express.
        let s = fresh()
        s.mode = .custom
        s.source = .tokenCounts
        s.window = .monthly
        s.customTokenBudgetMonthly = 2_000_000_000
        let q = s.makeQuery()
        XCTAssertEqual(q.source, .tokenCounts)
        XCTAssertEqual(q.window, .monthly)
        XCTAssertEqual(q.tokenBudget, 2_000_000_000)
    }

    func testDollarDisplayRequestsDollarStats() {
        let s = fresh()
        s.displayUnit = .dollars
        XCTAssertTrue(s.makeQuery().wantDollarStats)
        s.displayUnit = .percent
        XCTAssertFalse(s.makeQuery().wantDollarStats)
    }

    func testCustomCostMeasureShowsDollarsRegardlessOfToggle() {
        // In Custom mode the Measure choice drives the unit: picking Cost shows
        // dollars even when the stored (Detected-only) toggle still says percent.
        let s = fresh()
        s.mode = .custom
        s.displayUnit = .percent
        s.source = .costEstimate
        XCTAssertEqual(s.effectiveDisplayUnit, .dollars)
        XCTAssertTrue(s.makeQuery().wantDollarStats)
    }

    func testCustomTokenMeasureShowsPercentRegardlessOfToggle() {
        let s = fresh()
        s.mode = .custom
        s.displayUnit = .dollars
        s.source = .tokenCounts
        XCTAssertEqual(s.effectiveDisplayUnit, .percent)
        XCTAssertFalse(s.makeQuery().wantDollarStats)
    }

    func testDetectedModeHonorsDisplayUnitToggle() {
        // Detected mode keeps the explicit toggle — both units are valid there,
        // independent of the source.
        let s = fresh()
        s.mode = .detected
        s.source = .tokenCounts
        s.displayUnit = .dollars
        XCTAssertEqual(s.effectiveDisplayUnit, .dollars)
        XCTAssertTrue(s.makeQuery().wantDollarStats)
    }

    func testBudgetClamping() {
        let s = fresh()
        s.mode = .custom
        s.planPreset = .custom
        s.customCostBudget5h = -5
        s.customTokenBudget5h = 0
        s.costMultiplier = 0
        let q = s.makeQuery()
        XCTAssertGreaterThan(q.costBudget, 0)
        XCTAssertGreaterThan(q.tokenBudget, 0)
        XCTAssertGreaterThan(q.costMultiplier, 0)
    }

    func testPreferredLimitFlowsIntoQuery() {
        let s = fresh()
        s.selectedLimitID = "session|Session"
        XCTAssertEqual(s.makeQuery().preferredLimitID, "session|Session")
    }
}
