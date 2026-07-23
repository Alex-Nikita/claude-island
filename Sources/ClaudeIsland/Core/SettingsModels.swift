import Foundation

enum DisplayMode: String, Codable, CaseIterable {
    case pill
    case notch
}

// .detected (shown as "Claude account") = zero-config: plan and limits read
// from the logged-in Claude Code install (keychain credential + usage
// endpoint) — the ONLY mode that connects. Custom = a manual local estimate
// with your own source/window/budget; it never touches the keychain.
enum SettingsMode: String, Codable, CaseIterable, Identifiable {
    case detected
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        // The raw case stays `detected` for stored-defaults compatibility;
        // the label says what it actually is — your connected Claude account.
        case .detected: return "Claude account"
        case .custom: return "Custom"
        }
    }
}

// Color-vision types with meaningfully different safe palettes: the
// red-green deficiencies need the blue/amber axis, tritanopia is the
// opposite (blue/yellow collapses, red/green survives), and monochromacy
// needs lightness plus symbols.
enum ColorVision: String, Codable, CaseIterable, Identifiable {
    case standard
    case deuteranopia
    case protanopia
    case tritanopia
    case monochrome

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Default"
        case .deuteranopia: return "Deuteranopia (green-blind)"
        case .protanopia: return "Protanopia (red-blind)"
        case .tritanopia: return "Tritanopia (blue-blind)"
        case .monochrome: return "Monochrome"
        }
    }

    // Fits a segmented control; the caption spells out the full name.
    var shortTitle: String {
        switch self {
        case .standard: return "Default"
        case .deuteranopia: return "Deutan"
        case .protanopia: return "Protan"
        case .tritanopia: return "Tritan"
        case .monochrome: return "Mono"
        }
    }
}

enum UsageSource: String, Codable, CaseIterable, Identifiable {
    case officialAPI
    case tokenCounts
    case costEstimate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .officialAPI: return "Official API"
        case .tokenCounts: return "Cached usage (tokens)"
        case .costEstimate: return "Cost estimate"
        }
    }

    var help: String {
        switch self {
        case .officialAPI: return "Reads your real limit utilization from Anthropic's usage endpoint (uses the Claude Code keychain token)."
        case .tokenCounts: return "Sums the usage blocks Claude Code stores in ~/.claude/projects JSONL files against a token budget."
        case .costEstimate: return "Converts those tokens to dollars via per-model pricing, times your multiplier, against a cost budget."
        }
    }
}

// Whether the headline number counts down (left) or up (used) — the bare
// number is ambiguous without it.
enum PercentDisplay: String, Codable, CaseIterable, Identifiable {
    case left
    case used

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return "% left"
        case .used: return "% used"
        }
    }
}

// Headline unit: share of the limit, or money. Dollars are local estimates
// (per-model pricing × multiplier) unless the account meters real credits.
enum DisplayUnit: String, Codable, CaseIterable, Identifiable {
    case percent
    case dollars

    var id: String { rawValue }

    var title: String {
        switch self {
        case .percent: return "Percent"
        case .dollars: return "Dollars"
        }
    }
}

enum UsageWindow: String, Codable, CaseIterable, Identifiable {
    case fiveHour
    case weekly
    // Calendar month — the cadence of money (usage-based billing, credit
    // pools). Subscription windows never use it.
    case monthly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fiveHour: return "5-hour"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }

    // What the subscription window picker offers.
    static let subscriptionWindows: [UsageWindow] = [.fiveHour, .weekly]
}

enum PlanPreset: String, Codable, CaseIterable, Identifiable {
    case pro
    case max5x
    case max20x
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pro: return "Pro"
        case .max5x: return "Max 5×"
        case .max20x: return "Max 20×"
        case .custom: return "Custom"
        }
    }
}
