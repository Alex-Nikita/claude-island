import Foundation

enum Pricing {
    // Cache-token price ratios relative to plain input tokens. Anthropic
    // bills cache reads at 0.1×, 5-minute cache writes at 1.25×, and 1-hour
    // writes at 2× — and meters usage limits with the same weights, so
    // UsageEngine's weighted-token view reuses these. Single source: a
    // pricing change must never update one view and not the other.
    static let cacheReadWeight = 0.1
    static let cacheWrite5mWeight = 1.25
    static let cacheWrite1hWeight = 2.0

    private struct Rate {
        let prefix: String
        let input: Double
        let output: Double
    }

    // USD per 1M tokens. Matched by longest prefix, so specific rows beat generic ones.
    private static let rates: [Rate] = [
        Rate(prefix: "claude-fable-5", input: 10, output: 50),
        Rate(prefix: "claude-mythos", input: 10, output: 50),
        Rate(prefix: "claude-opus-4-1", input: 15, output: 75),
        Rate(prefix: "claude-opus-4-0", input: 15, output: 75),
        // Also catches date-suffixed claude-opus-4-2xxxxxxx (0514-era) ids.
        Rate(prefix: "claude-opus-4-2", input: 15, output: 75),
        Rate(prefix: "claude-opus-4", input: 5, output: 25),
        Rate(prefix: "claude-sonnet", input: 3, output: 15),
        Rate(prefix: "claude-3-7-sonnet", input: 3, output: 15),
        Rate(prefix: "claude-3-5-sonnet", input: 3, output: 15),
        Rate(prefix: "claude-3-sonnet", input: 3, output: 15),
        Rate(prefix: "claude-haiku-4-5", input: 1, output: 5),
        Rate(prefix: "claude-3-5-haiku", input: 0.8, output: 4),
        Rate(prefix: "claude-3-haiku", input: 0.25, output: 1.25)
    ]

    private static let fallback = Rate(prefix: "", input: 5, output: 25)

    // Sonnet 5 intro pricing ($2/$10) runs through 2026-08-31 UTC, then $3/$15.
    private static let sonnet5IntroEnd: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: components) ?? .distantFuture
    }()

    static func cost(model: String, totals: TokenTotals) -> Double {
        cost(model: model, totals: totals, at: Date())
    }

    static func cost(model: String, totals: TokenTotals, at date: Date) -> Double {
        let rate = bestRate(for: model, at: date)
        let dollars = totals.input * rate.input
            + totals.output * rate.output
            + totals.cacheRead * rate.input * cacheReadWeight
            + totals.cacheWrite5m * rate.input * cacheWrite5mWeight
            + totals.cacheWrite1h * rate.input * cacheWrite1hWeight
        return dollars / 1_000_000
    }

    private static func bestRate(for model: String, at date: Date) -> Rate {
        // Longer than any other matching prefix, so safe to special-case first.
        if model.hasPrefix("claude-sonnet-5") {
            return date < sonnet5IntroEnd
                ? Rate(prefix: "claude-sonnet-5", input: 2, output: 10)
                : Rate(prefix: "claude-sonnet-5", input: 3, output: 15)
        }
        var best: Rate?
        for rate in rates where model.hasPrefix(rate.prefix) {
            if rate.prefix.count > (best?.prefix.count ?? -1) {
                best = rate
            }
        }
        return best ?? fallback
    }
}
