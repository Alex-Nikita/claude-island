import XCTest
@testable import ClaudeIsland

final class PricingTests: XCTestCase {
    private func totals(
        input: Double = 0, output: Double = 0,
        cacheRead: Double = 0, write5m: Double = 0, write1h: Double = 0
    ) -> TokenTotals {
        var t = TokenTotals()
        t.input = input
        t.output = output
        t.cacheRead = cacheRead
        t.cacheWrite5m = write5m
        t.cacheWrite1h = write1h
        return t
    }

    func testFableRates() {
        XCTAssertEqual(Pricing.cost(model: "claude-fable-5", totals: totals(input: 1_000_000)), 10)
        XCTAssertEqual(Pricing.cost(model: "claude-fable-5", totals: totals(output: 1_000_000)), 50)
    }

    func testLongestPrefixWins() {
        // opus-4-1 (legacy $15) must beat the generic opus-4 ($5) row.
        XCTAssertEqual(Pricing.cost(model: "claude-opus-4-1-20250514", totals: totals(input: 1_000_000)), 15)
        // opus-4-8 falls through to the generic opus-4 row.
        XCTAssertEqual(Pricing.cost(model: "claude-opus-4-8", totals: totals(input: 1_000_000)), 5)
    }

    func testCacheMultipliers() {
        let model = "claude-fable-5" // input $10/M
        XCTAssertEqual(Pricing.cost(model: model, totals: totals(cacheRead: 1_000_000)), 1, accuracy: 0.001)
        XCTAssertEqual(Pricing.cost(model: model, totals: totals(write5m: 1_000_000)), 12.5, accuracy: 0.001)
        XCTAssertEqual(Pricing.cost(model: model, totals: totals(write1h: 1_000_000)), 20, accuracy: 0.001)
    }

    func testUnknownModelFallsBack() {
        XCTAssertEqual(Pricing.cost(model: "claude-nova-9", totals: totals(input: 1_000_000)), 5)
    }

    func testSonnet5IntroWindow() {
        let intro = Date(timeIntervalSince1970: 1_780_000_000)      // mid-2026, before Sep 1
        let after = Date(timeIntervalSince1970: 1_800_000_000)      // early 2027
        XCTAssertEqual(Pricing.cost(model: "claude-sonnet-5", totals: totals(input: 1_000_000), at: intro), 2)
        XCTAssertEqual(Pricing.cost(model: "claude-sonnet-5", totals: totals(input: 1_000_000), at: after), 3)
    }

    func testHaikuGenerations() {
        XCTAssertEqual(Pricing.cost(model: "claude-haiku-4-5-20251001", totals: totals(input: 1_000_000)), 1)
        XCTAssertEqual(Pricing.cost(model: "claude-3-5-haiku-20241022", totals: totals(input: 1_000_000)), 0.8)
        XCTAssertEqual(Pricing.cost(model: "claude-3-haiku-20240307", totals: totals(input: 1_000_000)), 0.25)
    }
}
