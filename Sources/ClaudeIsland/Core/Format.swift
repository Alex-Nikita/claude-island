import Foundation

// Every user-facing number format in one place, so the pill, dropdown, and
// island can never disagree about how the same value reads.
enum Format {
    /// Exact money, cents always shown: "$12.35", "$0.00".
    static func dollars(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    /// Pill-sized money: cents under $100, whole dollars to $1K, then "$1.2K".
    static func compactDollars(_ value: Double) -> String {
        if value >= 1000 { return String(format: "$%.1fK", value / 1000) }
        if value >= 100 { return String(format: "$%.0f", value) }
        return String(format: "$%.2f", value)
    }

    /// Token counts scaled to K/M/B, one decimal only when it matters.
    static func tokens(_ value: Double) -> String {
        let magnitude = abs(value)
        func scaled(_ divisor: Double, _ suffix: String) -> String {
            let rounded = (value / divisor * 10).rounded() / 10
            let format = rounded == rounded.rounded() ? "%.0f" : "%.1f"
            return String(format: format, rounded) + suffix
        }
        if magnitude >= 1_000_000_000 { return scaled(1_000_000_000, "B") }
        if magnitude >= 1_000_000 { return scaled(1_000_000, "M") }
        if magnitude >= 1_000 { return scaled(1_000, "K") }
        return String(format: "%.0f", value)
    }
}
