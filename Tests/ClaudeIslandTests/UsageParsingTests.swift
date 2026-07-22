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

    func testEpochMillisecondResetDates() throws {
        let usage = try parse("""
        {"five_hour":{"utilization":10,"resets_at":1784646000000}}
        """)
        XCTAssertEqual(
            usage.fiveHourResetsAt?.timeIntervalSince1970 ?? 0, 1_784_646_000, accuracy: 1
        )
    }
}
