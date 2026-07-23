import XCTest
@testable import ClaudeIsland

final class UpdateCheckerTests: XCTestCase {

    // MARK: - SemVer

    func testSemVerParsingNormalizes() {
        XCTAssertEqual(SemVer("1.2.3"), SemVer("v1.2.3"), "leading v is ignored")
        XCTAssertEqual(SemVer("1.2"), SemVer("1.2.0"), "missing patch defaults to 0")
        XCTAssertEqual(SemVer("2"), SemVer("2.0.0"))
        XCTAssertEqual(SemVer("1.4.0-beta.2"), SemVer("1.4.0"), "pre-release suffix ignored")
        XCTAssertEqual(SemVer("1.4.0+abc"), SemVer("1.4.0"), "build metadata ignored")
        XCTAssertNil(SemVer("not-a-version"))
        XCTAssertNil(SemVer(""))
    }

    func testSemVerOrdering() {
        XCTAssertTrue(SemVer("1.1.0")! < SemVer("1.2.0")!)
        XCTAssertTrue(SemVer("1.1.0")! < SemVer("1.1.1")!)
        XCTAssertTrue(SemVer("1.9.9")! < SemVer("2.0.0")!)
        XCTAssertFalse(SemVer("1.2.0")! < SemVer("1.2.0")!, "equal is not less-than")
        XCTAssertFalse(SemVer("v2.0.0")! < SemVer("1.9.9")!)
    }

    // MARK: - Release parsing

    private func releaseJSON(tag: String = "v1.2.0", draft: Bool = false,
                             prerelease: Bool = false) -> Data {
        Data("""
        {"tag_name":"\(tag)","name":"Claude Island \(tag)","body":"- did things\\n- fixed stuff",
         "html_url":"https://github.com/Alex-Nikita/claude-island/releases/tag/\(tag)",
         "draft":\(draft),"prerelease":\(prerelease),"published_at":"2026-07-23T10:00:00Z"}
        """.utf8)
    }

    func testParseReleaseHappyPath() {
        let info = UpdateChecker.parseRelease(releaseJSON())
        XCTAssertEqual(info?.tag, "v1.2.0")
        XCTAssertEqual(info?.version, "1.2.0", "leading v stripped for display")
        XCTAssertEqual(info?.name, "Claude Island v1.2.0")
        XCTAssertTrue(info?.notes.contains("fixed stuff") ?? false)
        XCTAssertTrue(info?.url.contains("releases/tag/v1.2.0") ?? false)
        XCTAssertNotNil(info?.publishedAt)
    }

    func testParseReleaseRejectsDraftAndPrerelease() {
        XCTAssertNil(UpdateChecker.parseRelease(releaseJSON(draft: true)),
                     "a draft is not a public release")
        XCTAssertNil(UpdateChecker.parseRelease(releaseJSON(prerelease: true)),
                     "a pre-release must not nag stable users")
    }

    func testParseReleaseRejectsGarbage() {
        XCTAssertNil(UpdateChecker.parseRelease(Data("{}".utf8)), "no tag_name")
        XCTAssertNil(UpdateChecker.parseRelease(Data("not json".utf8)))
    }

    // MARK: - Update decision

    private func release(tag: String) -> ReleaseInfo {
        ReleaseInfo(version: tag, tag: tag, name: tag, notes: "", url: "x", publishedAt: nil)
    }

    func testStatusReportsNewerReleaseAsAvailable() {
        let status = UpdateChecker.status(currentVersion: "1.1.0", release: release(tag: "v1.2.0"))
        XCTAssertEqual(status.release?.tag, "v1.2.0")
    }

    func testStatusReportsSameOrOlderAsUpToDate() {
        XCTAssertEqual(UpdateChecker.status(currentVersion: "1.1.0", release: release(tag: "v1.1.0")),
                       .upToDate(current: "1.1.0"), "same version is not an update")
        XCTAssertEqual(UpdateChecker.status(currentVersion: "2.0.0", release: release(tag: "v1.9.9")),
                       .upToDate(current: "2.0.0"), "an older release must never nag a newer build")
    }

    func testStatusDeclinesOnUnparseableVersion() {
        XCTAssertEqual(UpdateChecker.status(currentVersion: "not-a-version", release: release(tag: "v1.2.0")),
                       .unknown, "an uncomparable current version declines to nag")
        XCTAssertEqual(UpdateChecker.status(currentVersion: "1.1.0", release: release(tag: "nightly")),
                       .unknown, "an uncomparable tag declines to nag")
    }
}
