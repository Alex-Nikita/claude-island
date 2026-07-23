import Foundation

// One real limit from the account's usage endpoint, e.g. the session window,
// the all-models weekly window, or a per-model scoped weekly window.
struct OfficialLimit: Equatable, Identifiable {
    let kind: String
    let label: String
    let percentUsed: Double
    let severity: String
    let resetsAt: Date?
    let isActive: Bool

    var id: String { kind + "|" + label }
}

// What a logged-in Claude Code install tells us about the account.
struct DetectedAccount: Equatable {
    let subscriptionType: String
    let rateLimitTier: String?
    let planPreset: PlanPreset

    var planLabel: String {
        switch planPreset {
        case .pro: return "Claude Pro"
        case .max5x: return "Claude Max (5×)"
        case .max20x: return "Claude Max (20×)"
        case .custom: return "Claude (\(subscriptionType))"
        }
    }
}

struct UsageQuery {
    let source: UsageSource
    let window: UsageWindow
    let costMultiplier: Double
    let costBudget: Double
    let tokenBudget: Double
    let weightCacheTokens: Bool
    var mode: SettingsMode = .custom
    // Dollar stats need a JSONL cost scan on official-API paths — only
    // computed when the display actually shows dollars.
    var wantDollarStats: Bool = false
    // OfficialLimit.id the user chose to headline; nil = tightest limit.
    var preferredLimitID: String?
}

struct UsageSnapshot: Equatable {
    let percentLeft: Double
    let usedDisplay: String
    let budgetDisplay: String
    let windowLabel: String
    let sourceLabel: String
    let resetsAt: Date?
    let updatedAt: Date
    var officialLimits: [OfficialLimit] = []
    // Endpoint confirmed the account has no usage caps — display ∞, not %.
    var isUnlimited: Bool = false
    // No connected account AND no Custom plan chosen: the percentage would be
    // invented from a default budget the user never set, so show "–" instead
    // of a number that looks earned. Also suppresses the low-budget alarm color.
    var isUnconfigured: Bool = false
    // Money view of the same window: native credit figures when the account
    // has them, local cost estimates otherwise. Budget nil = no dollar cap.
    var dollarsUsed: Double?
    var dollarsBudget: Double?
    // Why the last official fetch failed, when it did — surfaced in Settings
    // so a degraded state is diagnosable (expired token vs HTTP vs keychain).
    var fetchErrorDescription: String? = nil
}
