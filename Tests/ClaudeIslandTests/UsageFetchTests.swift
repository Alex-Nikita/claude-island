import XCTest
@testable import ClaudeIsland

// Drives OAuthUsageFetcher.fetchUsage(token:) through a scripted transport so
// the 429 / 401 / serve-stale handling is covered without a network or the
// real keychain. The mock lives here in the test target — never in the app.
final class UsageFetchTests: XCTestCase {

    private final class MockTransport: UsageTransport, @unchecked Sendable {
        struct Reply { let status: Int; let headers: [String: String]; let body: Data }
        private let lock = NSLock()
        private var replies: [Reply]
        init(_ replies: [Reply]) { self.replies = replies }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            lock.lock()
            let reply = replies.isEmpty ? Reply(status: 200, headers: [:], body: Data())
                                        : replies.removeFirst()
            lock.unlock()
            let http = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: nil, headerFields: reply.headers)!
            return (reply.body, http)
        }
    }

    private func reply(_ status: Int, headers: [String: String] = [:], body: Data = Data())
        -> MockTransport.Reply {
        .init(status: status, headers: headers, body: body)
    }

    private let usageJSON = Data("""
    {"five_hour":{"utilization":8.0},"seven_day":{"utilization":27.0}}
    """.utf8)

    func testSuccessParsesUsage() async throws {
        let fetcher = OAuthUsageFetcher(transport: MockTransport([reply(200, body: usageJSON)]))
        let usage = try await fetcher.fetchUsage(token: "t")
        XCTAssertEqual(usage.fiveHourUtilization, 8.0)
        XCTAssertEqual(usage.sevenDayUtilization, 27.0)
    }

    func testRateLimitThrowsAndHonorsRetryAfter() async {
        let fetcher = OAuthUsageFetcher(transport: MockTransport([reply(429, headers: ["Retry-After": "120"])]))
        do {
            _ = try await fetcher.fetchUsage(token: "t")
            XCTFail("a 429 with no cached usage must throw")
        } catch let error as OAuthUsageFetcher.FetchError {
            guard case .rateLimited(let retryAt) = error, let retryAt else {
                return XCTFail("expected .rateLimited, got \(error)")
            }
            XCTAssertEqual(retryAt.timeIntervalSinceNow, 120, accuracy: 10,
                           "backoff honors the Retry-After header")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRateLimitServesLastGoodUsageInsteadOfBlanking() async throws {
        let fetcher = OAuthUsageFetcher(transport: MockTransport([
            reply(200, body: usageJSON),  // first: succeeds and caches
            reply(429),                   // second: rate-limited
        ]))
        let first = try await fetcher.fetchUsage(token: "t")
        let second = try await fetcher.fetchUsage(token: "t")
        XCTAssertEqual(second.fiveHourUtilization, first.fiveHourUtilization,
                       "a transient 429 serves the last good figure, not a blank or error")
    }

    func testTokenRejectionThrowsHTTPStatus() async {
        for code in [401, 403] {
            let fetcher = OAuthUsageFetcher(transport: MockTransport([reply(code)]))
            do {
                _ = try await fetcher.fetchUsage(token: "t")
                XCTFail("\(code) should throw")
            } catch let error as OAuthUsageFetcher.FetchError {
                guard case .httpStatus(let got) = error, got == code else {
                    return XCTFail("expected .httpStatus(\(code)), got \(error)")
                }
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    func testOtherHTTPErrorThrowsItsStatus() async {
        let fetcher = OAuthUsageFetcher(transport: MockTransport([reply(500)]))
        do {
            _ = try await fetcher.fetchUsage(token: "t")
            XCTFail("500 should throw")
        } catch let error as OAuthUsageFetcher.FetchError {
            guard case .httpStatus(500) = error else {
                return XCTFail("expected .httpStatus(500), got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
