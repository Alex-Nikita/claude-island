import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {
    // Refresh cadence for the usage scan loop; the Settings slider edits it
    // and AppState clamps to the same floor, so the two can't disagree.
    static let defaultRefreshSeconds: Double = 20
    static let refreshRange: ClosedRange<Double> = 10...120

    // Single source for every persisted key: the init read and the didSet
    // write must name the same case, so a typo can't silently split a
    // setting into one key it writes and another it reads.
    private enum Key: String {
        case displayMode, percentDisplay, displayUnit, hideIslandHooks
        case colorVision, statusSymbols, mode, connectAccount
        case selectedLimitID, detectedPlanPreset, accountKind, source, window
        case planPreset, costMultiplier
        case customCostBudget5h, customCostBudgetWeekly, customCostBudgetMonthly
        case customTokenBudget5h, customTokenBudgetWeekly
        case refreshSeconds, weightCacheTokens
        case autoExpandOnPrompt, collapseOnClickAway
        case checkForUpdates
        case authorizedBuildHash
        // Pre-typed-picker boolean, read once for migration.
        case legacyColorBlindPalette = "colorBlindPalette"
    }

    @Published var displayMode: DisplayMode { didSet { persist(displayMode.rawValue, .displayMode) } }
    @Published var percentDisplay: PercentDisplay { didSet { persist(percentDisplay.rawValue, .percentDisplay) } }
    @Published var displayUnit: DisplayUnit { didSet { persist(displayUnit.rawValue, .displayUnit) } }
    // The island installs a pile of hook entries of its own; keep them out
    // of the Hooks tab so the user's hooks stay visible.
    @Published var hideIslandHooks: Bool { didSet { persist(hideIslandHooks, .hideIslandHooks) } }
    // Accessibility: color-vision-safe semantic palette, and symbol overlays
    // so state never depends on color alone.
    @Published var colorVision: ColorVision { didSet { persist(colorVision.rawValue, .colorVision) } }
    @Published var statusSymbols: Bool { didSet { persist(statusSymbols, .statusSymbols) } }
    @Published var mode: SettingsMode { didSet { persist(mode.rawValue, .mode) } }
    // Reading the Claude Code credential (for real limits) triggers a macOS
    // keychain prompt and grants this app the account token — strictly
    // opt-in, never on by default.
    @Published var connectAccount: Bool { didSet { persist(connectAccount, .connectAccount) } }
    // Which account limit headlines the display; nil = tightest automatically.
    @Published var selectedLimitID: String? {
        didSet { persist(selectedLimitID ?? "", .selectedLimitID) }
    }
    // Last plan detected from the Claude Code credential, cached so fallback
    // budgets are right even before the first keychain read of a launch.
    @Published var detectedPlanPreset: PlanPreset? {
        didSet { persist(detectedPlanPreset?.rawValue ?? "", .detectedPlanPreset) }
    }
    @Published var accountKind: AccountKind { didSet { persist(accountKind.rawValue, .accountKind) } }
    @Published var source: UsageSource { didSet { persist(source.rawValue, .source) } }
    @Published var window: UsageWindow { didSet { persist(window.rawValue, .window) } }
    @Published var planPreset: PlanPreset { didSet { persist(planPreset.rawValue, .planPreset) } }
    @Published var costMultiplier: Double { didSet { persist(costMultiplier, .costMultiplier) } }
    @Published var customCostBudget5h: Double { didSet { persist(customCostBudget5h, .customCostBudget5h) } }
    @Published var customCostBudgetWeekly: Double { didSet { persist(customCostBudgetWeekly, .customCostBudgetWeekly) } }
    @Published var customCostBudgetMonthly: Double { didSet { persist(customCostBudgetMonthly, .customCostBudgetMonthly) } }
    @Published var customTokenBudget5h: Double { didSet { persist(customTokenBudget5h, .customTokenBudget5h) } }
    @Published var customTokenBudgetWeekly: Double { didSet { persist(customTokenBudgetWeekly, .customTokenBudgetWeekly) } }
    @Published var refreshSeconds: Double { didSet { persist(refreshSeconds, .refreshSeconds) } }
    // Cache reads are billed at 0.1x input price; counting them at full weight
    // makes any realistic token budget saturate within minutes of agent use.
    @Published var weightCacheTokens: Bool { didSet { persist(weightCacheTokens, .weightCacheTokens) } }
    // Island behavior. Auto-expand pops the island open when a session
    // starts waiting on an answer; click-away collapses it when a click
    // lands anywhere else on screen. Both mirror the long-standing built-in
    // behavior, so they default on.
    @Published var autoExpandOnPrompt: Bool { didSet { persist(autoExpandOnPrompt, .autoExpandOnPrompt) } }
    @Published var collapseOnClickAway: Bool { didSet { persist(collapseOnClickAway, .collapseOnClickAway) } }
    // Checks GitHub for a newer release on launch. Sends nothing about the
    // user — a plain GET to the public releases API — so it defaults on.
    @Published var checkForUpdates: Bool { didSet { persist(checkForUpdates, .checkForUpdates) } }
    // Code-signature hash of the build the user last granted keychain
    // access on. A matching hash lets the SAME build auto-reconnect at
    // launch via a silent no-UI probe; any rebuild breaks the match and
    // waits for the explicit click again (macOS would re-prompt anyway).
    @Published var authorizedBuildHash: String? {
        didSet { persist(authorizedBuildHash ?? "", .authorizedBuildHash) }
    }

    private static let prefix = "claudeIsland."
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func str(_ key: Key) -> String? { defaults.string(forKey: Self.prefix + key.rawValue) }
        func num(_ key: Key, _ fallback: Double) -> Double {
            defaults.object(forKey: Self.prefix + key.rawValue) == nil
                ? fallback
                : defaults.double(forKey: Self.prefix + key.rawValue)
        }
        func bool(_ key: Key, _ fallback: Bool) -> Bool {
            defaults.object(forKey: Self.prefix + key.rawValue) == nil
                ? fallback
                : defaults.bool(forKey: Self.prefix + key.rawValue)
        }
        displayMode = str(.displayMode).flatMap(DisplayMode.init(rawValue:)) ?? .pill
        percentDisplay = str(.percentDisplay).flatMap(PercentDisplay.init(rawValue:)) ?? .left
        hideIslandHooks = bool(.hideIslandHooks, true)
        // Migrate the short-lived boolean toggle to the typed picker.
        if let stored = str(.colorVision).flatMap(ColorVision.init(rawValue:)) {
            colorVision = stored
        } else {
            colorVision = bool(.legacyColorBlindPalette, false) ? .deuteranopia : .standard
        }
        statusSymbols = bool(.statusSymbols, false)
        displayUnit = str(.displayUnit).flatMap(DisplayUnit.init(rawValue:)) ?? .percent
        mode = str(.mode).flatMap(SettingsMode.init(rawValue:)) ?? .detected
        connectAccount = bool(.connectAccount, false)
        let storedLimit = str(.selectedLimitID) ?? ""
        selectedLimitID = storedLimit.isEmpty ? nil : storedLimit
        detectedPlanPreset = str(.detectedPlanPreset).flatMap(PlanPreset.init(rawValue:))
        accountKind = str(.accountKind).flatMap(AccountKind.init(rawValue:)) ?? .subscription
        source = str(.source).flatMap(UsageSource.init(rawValue:)) ?? .tokenCounts
        window = str(.window).flatMap(UsageWindow.init(rawValue:)) ?? .fiveHour
        planPreset = str(.planPreset).flatMap(PlanPreset.init(rawValue:)) ?? .max5x
        costMultiplier = num(.costMultiplier, 1.0)
        customCostBudget5h = num(.customCostBudget5h, 35)
        customCostBudgetWeekly = num(.customCostBudgetWeekly, 300)
        customCostBudgetMonthly = num(.customCostBudgetMonthly, 1000)
        customTokenBudget5h = num(.customTokenBudget5h, 50_000_000)
        customTokenBudgetWeekly = num(.customTokenBudgetWeekly, 300_000_000)
        refreshSeconds = num(.refreshSeconds, Self.defaultRefreshSeconds)
        weightCacheTokens = bool(.weightCacheTokens, true)
        autoExpandOnPrompt = bool(.autoExpandOnPrompt, true)
        collapseOnClickAway = bool(.collapseOnClickAway, true)
        checkForUpdates = bool(.checkForUpdates, true)
        let storedHash = str(.authorizedBuildHash) ?? ""
        authorizedBuildHash = storedHash.isEmpty ? nil : storedHash
        // Invariant: connected ⟹ a build blessing is recorded. The pair
        // is written together, so "connected" with no blessing is an
        // inconsistent state (hand-edited defaults, a cleared record) — and
        // showing a Connected UI with no grant behind it reads as a lie.
        // Repair to the plain Connect flow. (persist directly: didSet
        // observers don't fire inside init.)
        if connectAccount, authorizedBuildHash == nil {
            connectAccount = false
            persist(false, .connectAccount)
        }
        // The official/keychain path now lives solely in "Claude account"
        // mode; Official API is no longer a selectable Custom source. Migrate a
        // persisted officialAPI selection to the local token estimate so the
        // Custom source picker always has a valid, visible radio selection.
        if source == .officialAPI {
            source = .tokenCounts
            persist(source.rawValue, .source)
        }
    }

    private func persist(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: Self.prefix + key.rawValue)
    }

    // Toggle-shaped view of the display mode: writing routes through
    // displayMode's didSet, so persistence and mode switching stay in one
    // place. Both the pill dropdown and the settings form bind to this.
    var notchModeEnabled: Bool {
        get { displayMode == .notch }
        set { displayMode = newValue ? .notch : .pill }
    }

    // In Detected mode the plan comes from the Claude Code credential; the
    // user's manual preset only applies in Custom mode.
    var effectivePlanPreset: PlanPreset {
        mode == .detected ? (detectedPlanPreset ?? planPreset) : planPreset
    }

    // Budget defaults per plan are community estimates — editable via Custom.
    func costBudget(for window: UsageWindow) -> Double {
        if window == .monthly { return customCostBudgetMonthly }
        switch (effectivePlanPreset, window) {
        case (.pro, .fiveHour): return 18
        case (.pro, _): return 80
        case (.max5x, .fiveHour): return 35
        case (.max5x, _): return 300
        case (.max20x, .fiveHour): return 140
        case (.max20x, _): return 1200
        case (.custom, .fiveHour): return customCostBudget5h
        case (.custom, _): return customCostBudgetWeekly
        }
    }

    func tokenBudget(for window: UsageWindow) -> Double {
        switch (effectivePlanPreset, window) {
        case (.pro, .fiveHour): return 10_000_000
        case (.pro, _): return 60_000_000
        case (.max5x, .fiveHour): return 50_000_000
        case (.max5x, _): return 300_000_000
        case (.max20x, .fiveHour): return 200_000_000
        case (.max20x, _): return 1_200_000_000
        case (.custom, .fiveHour): return customTokenBudget5h
        case (.custom, _): return customTokenBudgetWeekly
        }
    }

    func makeQuery() -> UsageQuery {
        // Usage-based accounts have no windows: spend is estimated locally
        // against a monthly calendar budget (the OAuth usage endpoint
        // returns nothing for them).
        let usageBased = mode == .custom && accountKind == .usageBased
        let effectiveWindow = usageBased ? .monthly : window
        // Clamp here rather than fighting the TextFields: a 0 or negative
        // budget/multiplier would pin the pill to 0% or 100%.
        return UsageQuery(
            // Detected mode uses the account endpoint only after the user
            // explicitly connects; otherwise it runs on local estimates.
            source: mode == .detected
                ? (connectAccount ? .officialAPI : .tokenCounts)
                : (usageBased ? .costEstimate : source),
            window: effectiveWindow,
            costMultiplier: max(0.01, costMultiplier),
            costBudget: max(0.01, costBudget(for: effectiveWindow)),
            tokenBudget: max(1, tokenBudget(for: effectiveWindow)),
            weightCacheTokens: weightCacheTokens,
            mode: mode,
            wantDollarStats: displayUnit == .dollars,
            preferredLimitID: selectedLimitID
        )
    }
}
