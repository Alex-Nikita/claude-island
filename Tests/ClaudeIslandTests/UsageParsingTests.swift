import XCTest
@testable import ClaudeIsland

final class UsageParsingTests: XCTestCase {
    private func parse(_ json: String) throws -> OfficialUsage {
        try OAuthUsageFetcher.parseUsage(json.data(using: .utf8)!)
    }

    // The per-launch gate: an unauthorized fetcher must fail BEFORE any
    // keychain access, so app launch can never trigger a credentials
    // prompt. (Never call authorize() in tests — the armed path would hit
    // the real keychain.)
    func testKeychainAccessRequiresPerLaunchAuthorization() async {
        let fetcher = OAuthUsageFetcher()
        do {
            _ = try await fetcher.fetch()
            XCTFail("unauthorized fetch must throw")
        } catch let error as OAuthUsageFetcher.FetchError {
            guard case .notConnected = error else {
                return XCTFail("expected notConnected, got \(error)")
            }
        } catch {
            XCTFail("unexpected error type \(error)")
        }
        let account = await fetcher.detectAccount()
        XCTAssertNil(account, "account detection sits behind the same gate")
    }

    func testBuildIdentityHashIsStable() {
        let first = BuildIdentity.currentCodeHash()
        XCTAssertNotNil(first, "the test runner is a signed binary")
        XCTAssertEqual(first, BuildIdentity.currentCodeHash(), "same run, same hash")
        XCTAssertTrue(first?.allSatisfy(\.isHexDigit) ?? false)
    }

    // Retry-After drives the 429 backoff. Delta-seconds and HTTP-date forms
    // both parse; junk falls through to nil (the fixed backoff covers it); a
    // wild value is clamped so a hostile header can't wedge the source off.
    func testRetryAfterParsing() {
        XCTAssertEqual(OAuthUsageFetcher.retryAfterSeconds("120"), 120)
        XCTAssertEqual(OAuthUsageFetcher.retryAfterSeconds("  0 "), 0)
        XCTAssertEqual(OAuthUsageFetcher.retryAfterSeconds("-5"), 0, "negative clamps up to 0")
        XCTAssertEqual(OAuthUsageFetcher.retryAfterSeconds("999999"), 3600, "clamped to the 1h ceiling")
        XCTAssertNil(OAuthUsageFetcher.retryAfterSeconds("soon"))
        XCTAssertNil(OAuthUsageFetcher.retryAfterSeconds(""))
        // A well-formed HTTP date in the past parses (proving date handling)
        // and clamps to 0 rather than returning nil.
        XCTAssertEqual(OAuthUsageFetcher.retryAfterSeconds("Wed, 21 Oct 2015 07:28:00 GMT"), 0)
    }

    func testPercentWindowsAndLimits() throws {
        let usage = try parse("""
        {"five_hour":{"utilization":8.0,"resets_at":"2026-07-21T21:09:59.998869+00:00"},
         "seven_day":{"utilization":27.0,"resets_at":"2026-07-27T18:59:59.998926+00:00"},
         "limits":[
           {"kind":"session","group":"session","percent":8,"severity":"normal","resets_at":"2026-07-21T21:09:59.998869+00:00","scope":null,"is_active":false},
           {"kind":"weekly_all","group":"weekly","percent":27,"severity":"normal","resets_at":null,"scope":null,"is_active":false},
           {"kind":"weekly_scoped","group":"weekly","percent":45,"severity":"warning","resets_at":null,"scope":{"model":{"id":null,"display_name":"Fable"}},"is_active":true}]}
        """)
        XCTAssertEqual(usage.fiveHourUtilization, 8)
        XCTAssertEqual(usage.sevenDayUtilization, 27)
        XCTAssertNotNil(usage.fiveHourResetsAt)
        XCTAssertEqual(usage.limits.count, 3)
        XCTAssertEqual(usage.limits[0].label, "Session")
        XCTAssertEqual(usage.limits[1].label, "Weekly (all models)")
        XCTAssertEqual(usage.limits[2].label, "Weekly · Fable")
        XCTAssertEqual(usage.limits[2].severity, "warning")
        XCTAssertTrue(usage.limits[2].isActive)
        XCTAssertFalse(usage.isUnlimited)
    }

    func testDollarWindows() throws {
        let usage = try parse("""
        {"five_hour":{"utilization":null,"resets_at":"2026-07-21T21:00:00+00:00","limit_dollars":50.0,"used_dollars":12.34},
         "seven_day":{"utilization":null,"resets_at":null,"limit_dollars":null,"used_dollars":null},
         "limits":[]}
        """)
        XCTAssertNil(usage.fiveHourUtilization)
        XCTAssertEqual(usage.fiveHourDollars?.used, 12.34)
        XCTAssertEqual(usage.fiveHourDollars?.limit, 50)
        XCTAssertNil(usage.sevenDayDollars)
        XCTAssertFalse(usage.isUnlimited)
    }

    func testUnlimitedAccountParsesInsteadOfThrowing() throws {
        let usage = try parse("""
        {"five_hour":{"utilization":null,"resets_at":null,"limit_dollars":null,"used_dollars":null},
         "seven_day":{"utilization":null,"resets_at":null,"limit_dollars":null,"used_dollars":142.10},
         "limits":[]}
        """)
        XCTAssertTrue(usage.isUnlimited)
        XCTAssertEqual(usage.sevenDayDollars?.used, 142.10)
        XCTAssertNil(usage.sevenDayDollars?.limit)
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try parse(#"{"unrelated": true}"#))
        XCTAssertThrowsError(try parse("not json at all"))
    }

    func testUnknownLimitKindGetsPrettifiedLabel() throws {
        let usage = try parse("""
        {"five_hour":{"utilization":1},
         "limits":[{"kind":"daily_special","percent":5,"severity":"normal","resets_at":null,"scope":null,"is_active":false}]}
        """)
        XCTAssertEqual(usage.limits.first?.label, "Daily Special")
    }

    func testLimitPercentClamped() throws {
        let usage = try parse("""
        {"five_hour":{"utilization":1},
         "limits":[{"kind":"session","percent":250,"severity":"exceeded","resets_at":null,"scope":null,"is_active":true}]}
        """)
        XCTAssertEqual(usage.limits.first?.percentUsed, 100)
    }

    // Enterprise credit-metered seat (rateLimitTier "default_claude_zero"):
    // null windows, empty limits, real usage only in top-level spend /
    // extra_usage. Exact shape from a live account report — the parser used
    // to throw unrecognizedResponse for it.
    private static let creditAccountJSON = """
    {"five_hour":null,"seven_day":null,"limits":[],
     "extra_usage":{"is_enabled":true,"monthly_limit":40000,"used_credits":27992.0,
       "utilization":69.98,"currency":"USD","decimal_places":2,"disabled_reason":null},
     "spend":{"used":{"amount_minor":27992,"currency":"USD","exponent":2},
       "limit":{"amount_minor":40000,"currency":"USD","exponent":2},
       "percent":70,"severity":"normal","enabled":true,"disabled_reason":null},
     "member_dashboard_available":true}
    """

    func testCreditMeteredAccountParses() throws {
        let usage = try parse(Self.creditAccountJSON)
        XCTAssertEqual(usage.monthlyCredits?.used ?? 0, 279.92, accuracy: 0.001)
        XCTAssertEqual(usage.monthlyCredits?.limit ?? 0, 400.00, accuracy: 0.001)
        XCTAssertFalse(usage.isUnlimited)
        let credit = usage.limits.first { $0.kind == "monthly_credits" }
        XCTAssertEqual(credit?.label, "Monthly credits")
        XCTAssertEqual(credit?.percentUsed ?? 0, 70, accuracy: 0.1)
        XCTAssertEqual(credit?.severity, "normal")
    }

    func testCreditAccountHeadlinesInDetectedMode() throws {
        let usage = try parse(Self.creditAccountJSON)
        let query = UsageQuery(source: .officialAPI, window: .fiveHour, costMultiplier: 1,
                               costBudget: 0, tokenBudget: 0, weightCacheTokens: true,
                               mode: .detected)
        let snapshot = UsageEngine().officialSnapshot(usage: usage, query: query)
        XCTAssertEqual(snapshot?.windowLabel, "Monthly credits")
        XCTAssertEqual(snapshot?.percentLeft ?? 0, 30, accuracy: 0.1)
        XCTAssertEqual(snapshot?.usedDisplay, Format.dollars(279.92) + " used")
        XCTAssertEqual(snapshot?.budgetDisplay, Format.dollars(400) + " credits")
        XCTAssertEqual(snapshot?.dollarsUsed ?? 0, 279.92, accuracy: 0.001)
    }

    func testExtraUsageFallbackWhenSpendMissing() throws {
        let usage = try parse("""
        {"five_hour":null,"seven_day":null,"limits":[],
         "extra_usage":{"is_enabled":true,"monthly_limit":40000,"used_credits":27992.0,
           "utilization":69.98,"currency":"USD","decimal_places":2,"disabled_reason":null}}
        """)
        XCTAssertEqual(usage.monthlyCredits?.used ?? 0, 279.92, accuracy: 0.001)
        XCTAssertEqual(usage.monthlyCredits?.limit ?? 0, 400, accuracy: 0.001)
        XCTAssertEqual(usage.limits.first?.percentUsed ?? 0, 69.98, accuracy: 0.01)
    }

    func testDisabledCreditMeteringParsesAsUncapped() throws {
        let usage = try parse("""
        {"five_hour":null,"seven_day":null,"limits":[],
         "spend":{"used":{"amount_minor":0,"currency":"USD","exponent":2},
           "limit":null,"percent":0,"severity":"normal","enabled":false,
           "disabled_reason":"billing_paused"}}
        """)
        XCTAssertNil(usage.monthlyCredits, "disabled metering carries no cap")
        XCTAssertTrue(usage.isUnlimited, "present-but-disabled metering is not an error")
    }

    func testEpochMillisecondResetDates() throws {
        let usage = try parse("""
        {"five_hour":{"utilization":10,"resets_at":1784646000000}}
        """)
        XCTAssertEqual(
            usage.fiveHourResetsAt?.timeIntervalSince1970 ?? 0, 1_784_646_000, accuracy: 1
        )
    }
}
