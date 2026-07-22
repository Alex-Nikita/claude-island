import SwiftUI

// The island's palette and display thresholds, in one place.

extension Color {
    static let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)   // #D97757
    static let claudeRed = Color(red: 0.79, green: 0.23, blue: 0.18)      // low-budget warning
    static let attentionBeige = Color(red: 0.93, green: 0.86, blue: 0.62) // waiting on the user

    // Recurring surface tints on the black island.
    static let islandHairline = Color.white.opacity(0.09)
    static let islandChipFill = Color.white.opacity(0.12)
    static let cacheReadPurple = Color(red: 0.51, green: 0.49, blue: 0.74)
    static let pickerBackground = Color(red: 0.09, green: 0.09, blue: 0.1)
}

// Display thresholds shared by every surface, so the pill and the island
// flip to warning colors at the same moment.
enum Thresholds {
    // Context fill at which runtime lines and % readouts turn the warning
    // color (aligned with Claude Code's own context-crunch warnings).
    static let contextWarningPercent = 80
    // percentLeft below this renders the low-budget color everywhere.
    static let lowBudgetPercentLeft: Double = 10
}

extension SessionInfo {
    /// High-context sessions get the warning color wherever context shows.
    var contextIsHigh: Bool { (contextPercent ?? 0) >= Thresholds.contextWarningPercent }
}

extension UsageSnapshot {
    var isLowBudget: Bool { percentLeft < Thresholds.lowBudgetPercentLeft }
}

extension ContextBreakdown {
    var isHighUsage: Bool { usedPercent >= Double(Thresholds.contextWarningPercent) }
}

// Semantic state colors tuned per color-vision type (Okabe-Ito derived).
struct SemanticColors {
    let working: Color
    let idle: Color
    let waiting: Color
    let low: Color
    let active: Color

    static let standard = SemanticColors(
        working: .green,
        idle: .yellow,
        waiting: .attentionBeige,
        low: .claudeRed,
        active: .green
    )

    // Green-blind: blue/amber axis; vermillion separates from amber by
    // lightness rather than hue.
    static let deuteranopia = SemanticColors(
        working: Color(red: 0.00, green: 0.45, blue: 0.70),
        idle: Color(red: 0.63, green: 0.63, blue: 0.63),
        waiting: Color(red: 0.90, green: 0.62, blue: 0.00),
        low: Color(red: 0.84, green: 0.37, blue: 0.00),
        active: Color(red: 0.34, green: 0.71, blue: 0.91)
    )

    // Red-blind: like deuteranopia but deep reds go near-black, so warning
    // states shift to bright yellow / amber instead of vermillion.
    static let protanopia = SemanticColors(
        working: Color(red: 0.00, green: 0.45, blue: 0.70),
        idle: Color(red: 0.63, green: 0.63, blue: 0.63),
        waiting: Color(red: 0.94, green: 0.89, blue: 0.26),
        low: Color(red: 0.90, green: 0.62, blue: 0.00),
        active: Color(red: 0.34, green: 0.71, blue: 0.91)
    )

    // Blue-blind: blue/yellow collapses; the red/green axis survives, so
    // this palette leans on exactly what the others avoid.
    static let tritanopia = SemanticColors(
        working: Color(red: 0.00, green: 0.62, blue: 0.45),
        idle: Color(red: 0.63, green: 0.63, blue: 0.63),
        waiting: Color(red: 0.90, green: 0.62, blue: 0.00),
        low: Color(red: 0.70, green: 0.09, blue: 0.17),
        active: Color(red: 0.40, green: 0.76, blue: 0.65)
    )

    // Monochromacy: lightness ladder only — symbols carry the real signal
    // and are force-enabled with this palette.
    static let monochrome = SemanticColors(
        working: Color(white: 0.95),
        idle: Color(white: 0.50),
        waiting: Color(white: 0.78),
        low: .white,
        active: Color(white: 0.88)
    )

    static func palette(for vision: ColorVision) -> SemanticColors {
        switch vision {
        case .standard: return .standard
        case .deuteranopia: return .deuteranopia
        case .protanopia: return .protanopia
        case .tritanopia: return .tritanopia
        case .monochrome: return .monochrome
        }
    }
}
