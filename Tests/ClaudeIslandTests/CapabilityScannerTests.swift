import XCTest
@testable import ClaudeIsland

final class CapabilityScannerTests: XCTestCase {
    private var home: FixtureHome!
    private let scanner = CapabilityScanner()
    private var repo: URL!

    override func setUpWithError() throws {
        home = try FixtureHome()
        repo = try home.mkdir("Documents/monorepo")
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        home.tearDown()
        home = nil
    }

    private func skill(_ dir: String, name: String, description: String = "desc") throws {
        _ = try home.write(
            "Documents/monorepo/\(dir)/SKILL.md",
            "---\nname: \(name)\ndescription: \(description)\n---\nBody\n"
        )
    }

    func testMonorepoDiscovery() throws {
        try skill(".claude/skills/repo-wide", name: "repo-wide")
        try skill("apps/web/.claude/skills/deploy-web", name: "deploy-web")
        try skill("services/deep/nested/.claude/skills/edge", name: "edge-of-depth")
        try skill("services/deep/nested/really/.claude/skills/hidden", name: "too-deep")
        try skill("node_modules/pkg/.claude/skills/never", name: "never-appear")

        let caps = scanner.scan(cwd: repo.path)
        let names = caps.skills.map(\.name)
        XCTAssertTrue(names.contains("repo-wide"))
        XCTAssertTrue(names.contains("deploy-web"))
        XCTAssertTrue(names.contains("edge-of-depth"), "depth 3 is inside the bound")
        XCTAssertFalse(names.contains("too-deep"), "depth 4 is out of bounds")
        XCTAssertFalse(names.contains("never-appear"), "node_modules is skipped")

        XCTAssertEqual(caps.skills.first { $0.name == "deploy-web" }?.source, "apps/web")
        XCTAssertEqual(caps.skills.first { $0.name == "repo-wide" }?.source, "project")
    }

    func testAncestorDiscoveryStopsAtGitRoot() throws {
        try skill(".claude/skills/root-skill", name: "root-skill")
        let sub = repo.appendingPathComponent("apps/web")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        // A .claude ABOVE the git root must not be picked up.
        _ = try home.write(
            "Documents/.claude/skills/outside/SKILL.md",
            "---\nname: outside\ndescription: nope\n---\n"
        )

        let caps = scanner.scan(cwd: sub.path)
        let bySource = Dictionary(grouping: caps.skills, by: \.source)
        XCTAssertNotNil(bySource["monorepo ↑"], "repo root found from the subfolder")
        XCTAssertEqual(bySource["monorepo ↑"]?.first?.name, "root-skill")
        XCTAssertFalse(caps.skills.contains { $0.name == "outside" },
                       "the walk stops at the git root")
    }

    func testFrontmatterParsingQuirks() throws {
        _ = try home.write(
            "Documents/monorepo/.claude/skills/quoted/SKILL.md",
            "---\nname: \"quoted-name\"\ndescription: 'single quoted'\n---\n"
        )
        _ = try home.write(
            "Documents/monorepo/.claude/skills/bare-dir/SKILL.md",
            "---\ndescription: no name key\n---\n"
        )
        _ = try home.write(
            "Documents/monorepo/.claude/skills/no-front/SKILL.md",
            "Just some markdown, no frontmatter.\n"
        )
        let caps = scanner.scan(cwd: repo.path)
        XCTAssertTrue(caps.skills.contains { $0.name == "quoted-name" && $0.detail == "single quoted" })
        XCTAssertTrue(caps.skills.contains { $0.name == "bare-dir" }, "directory name fallback")
        XCTAssertTrue(caps.skills.contains { $0.name == "no-front" && $0.detail.isEmpty })
    }

    func testSkillPathsPointAtTheirFiles() throws {
        try skill(".claude/skills/pathy", name: "pathy")
        let caps = scanner.scan(cwd: repo.path)
        let path = caps.skills.first { $0.name == "pathy" }?.path
        XCTAssertTrue(path?.hasSuffix("skills/pathy/SKILL.md") ?? false)
    }

    func testSubagentsAndHooks() throws {
        _ = try home.write(
            "Documents/monorepo/.claude/agents/captain.md",
            "---\nname: captain\ndescription: leads\n---\n"
        )
        _ = try home.writeJSON("Documents/monorepo/.claude/settings.json", [
            "hooks": ["PreToolUse": [[
                "matcher": "Bash",
                "hooks": [["type": "command", "command": "guard.sh"]],
            ]]],
        ])
        let caps = scanner.scan(cwd: repo.path)
        XCTAssertTrue(caps.subagents.contains { $0.name == "captain" })
        let hook = caps.hooks.first { $0.command == "guard.sh" }
        XCTAssertEqual(hook?.event, "PreToolUse")
        XCTAssertEqual(hook?.matcher, "Bash")
        XCTAssertEqual(hook?.source, "project")
        XCTAssertTrue(hook?.sourcePath?.hasSuffix("settings.json") ?? false)
    }

    func testUserScopeItemsIncluded() throws {
        _ = try home.write(
            ".claude/skills/personal/SKILL.md",
            "---\nname: personal-skill\ndescription: mine\n---\n"
        )
        let caps = scanner.scan(cwd: repo.path)
        XCTAssertEqual(caps.skills.first { $0.name == "personal-skill" }?.source, "user")
    }
}
