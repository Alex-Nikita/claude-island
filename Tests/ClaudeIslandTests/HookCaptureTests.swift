import XCTest
@testable import ClaudeIsland

final class HookCaptureTests: XCTestCase {
    private var home: FixtureHome!

    override func setUpWithError() throws {
        home = try FixtureHome()
    }

    override func tearDown() {
        home.tearDown()
        home = nil
    }

    private func writeEvents(_ events: [[String: Any]], sessionId: String = "s") throws {
        _ = try home.writeLines(".claude/island/events/\(sessionId).jsonl", events)
    }

    private func latest(_ sessionId: String = "s", notBefore: Date? = nil) -> HookCapture.PromptState? {
        HookCapture.latestState(sessionId: sessionId, notBefore: notBefore)
    }

    // MARK: - Pending reader state machine

    func testPendingQuestionFromPreToolUse() throws {
        try writeEvents([hookEvent("PreToolUse", tool: "AskUserQuestion", input: askInput())])
        guard case .pending(let tool, let input, _, _)? = latest() else {
            return XCTFail("expected pending")
        }
        XCTAssertEqual(tool, "AskUserQuestion")
        XCTAssertNotNil(input["questions"])
    }

    func testSkillPreToolUseIsNotADialog() throws {
        try writeEvents([hookEvent("PreToolUse", tool: "Skill", input: ["skill": "dataviz"])])
        guard case .resolved? = latest() else {
            return XCTFail("a Skill load must never read as a pending dialog")
        }
    }

    func testPreAndPermissionForSameDialogDedupe() throws {
        let input = askInput()
        try writeEvents([
            hookEvent("PreToolUse", tool: "AskUserQuestion", input: input, toolUseId: "t1"),
            hookEvent("PermissionRequest", tool: "AskUserQuestion", input: input),
        ])
        guard case .pending? = latest() else { return XCTFail("expected pending") }
        // Resolving once must clear it fully — no phantom twin.
        try writeEvents([
            hookEvent("PreToolUse", tool: "AskUserQuestion", input: input, toolUseId: "t1"),
            hookEvent("PermissionRequest", tool: "AskUserQuestion", input: input),
            hookEvent("PostToolUse", tool: "AskUserQuestion", toolUseId: "t1"),
        ])
        guard case .resolved? = latest() else { return XCTFail("expected resolved") }
    }

    func testQueuedDialogsShowOldestFirst() throws {
        try writeEvents([
            hookEvent("PermissionRequest", tool: "Bash", input: ["command": "first"]),
            hookEvent("PermissionRequest", tool: "Bash", input: ["command": "second"]),
        ])
        guard case .pending(_, let input, _, _)? = latest() else { return XCTFail() }
        XCTAssertEqual(input["command"] as? String, "first", "dialogs display FIFO")
    }

    func testMarkerRemovesByToolNameFIFO() throws {
        try writeEvents([
            hookEvent("PermissionRequest", tool: "Bash", input: ["command": "first"]),
            hookEvent("PermissionRequest", tool: "Bash", input: ["command": "second"]),
            hookEvent("PostToolUse", tool: "Bash", toolUseId: "tX"),
        ])
        guard case .pending(_, let input, _, _)? = latest() else { return XCTFail() }
        XCTAssertEqual(input["command"] as? String, "second")
    }

    func testUnmatchedMarkerIsIgnored() throws {
        // Auto-approved tool completing must not clear an unrelated dialog.
        try writeEvents([
            hookEvent("PermissionRequest", tool: "AskUserQuestion", input: askInput()),
            hookEvent("PostToolUse", tool: "Read", toolUseId: "tR"),
        ])
        guard case .pending? = latest() else {
            return XCTFail("marker for a different tool must not clear the dialog")
        }
    }

    func testTurnBoundariesClearEverything() throws {
        for boundary in ["Stop", "UserPromptSubmit", "SessionEnd", "IslandStatusClear"] {
            try writeEvents([
                hookEvent("PermissionRequest", tool: "Bash", input: ["command": "x"]),
                hookEvent(boundary),
            ])
            guard case .resolved? = latest() else {
                return XCTFail("\(boundary) must clear pendings")
            }
        }
    }

    func testNotificationFallbackWhenNoInputEventCaptured() throws {
        try writeEvents([
            hookEvent("Stop"),
            hookEvent("Notification", message: "Claude Code needs your input"),
        ])
        guard case .pendingMessage(let message)? = latest() else {
            return XCTFail("expected message fallback")
        }
        XCTAssertTrue(message.contains("needs your input"))
    }

    func testPendingOutranksNotification() throws {
        try writeEvents([
            hookEvent("PermissionRequest", tool: "AskUserQuestion", input: askInput()),
            hookEvent("Notification", message: "Claude needs your permission"),
        ])
        guard case .pending? = latest() else {
            return XCTFail("the input-carrying event should win over its own notification")
        }
    }

    func testFreshnessGateRejectsStaleFiles() throws {
        try writeEvents([hookEvent("PermissionRequest", tool: "Bash", input: ["command": "old"])])
        try home.setModificationDate(".claude/island/events/s.jsonl", Date(timeIntervalSinceNow: -3600))
        XCTAssertNil(latest(notBefore: Date(timeIntervalSinceNow: -60)))
    }

    func testMissingFileYieldsNil() {
        XCTAssertNil(latest("nope"))
    }

    // MARK: - Status payload reader

    func testStatusInfoParsesContextAndBreakdown() throws {
        _ = try home.writeJSON(".claude/island/status/s.json", [
            "session_id": "s",
            "model": ["id": "claude-fable-5", "display_name": "Fable 5"],
            "effort": ["level": "xhigh"],
            "workspace": ["current_dir": "/tmp/proj"],
            "context_window": [
                "context_window_size": 1_000_000,
                "used_percentage": 57.4,
                "current_usage": [
                    "input_tokens": 2, "output_tokens": 900,
                    "cache_creation_input_tokens": 5635, "cache_read_input_tokens": 568_000,
                ],
            ],
        ])
        let info = HookCapture.statusInfo(sessionId: "s")
        XCTAssertEqual(info?.model, "Fable 5")
        XCTAssertEqual(info?.effortLevel, "xhigh")
        XCTAssertEqual(info?.contextPercent ?? 0, 57.4, accuracy: 0.01)
        XCTAssertEqual(info?.breakdown?.windowSize, 1_000_000)
        XCTAssertEqual(info?.breakdown?.usedTokens ?? 0, 573_637, accuracy: 1)
    }

    func testStatusInfoFallsBackByWorkingDirectory() throws {
        _ = try home.writeJSON(".claude/island/status/other-id.json", [
            "session_id": "other-id",
            "model": ["display_name": "Fable 5"],
            "workspace": ["current_dir": "/tmp/proj"],
            "context_window": ["context_window_size": 200_000, "used_percentage": 10],
        ])
        // Background-job sessions report a different id than the registry.
        let info = HookCapture.statusInfo(sessionId: "registry-id", cwd: "/tmp/proj")
        XCTAssertEqual(info?.model, "Fable 5")
        XCTAssertNil(HookCapture.statusInfo(sessionId: "registry-id", cwd: "/tmp/elsewhere"))
    }

    func testStatusInfoRespectsMaxAge() throws {
        _ = try home.writeJSON(".claude/island/status/s.json", [
            "session_id": "s", "context_window": ["used_percentage": 10],
        ])
        try home.setModificationDate(".claude/island/status/s.json", Date(timeIntervalSinceNow: -3600))
        XCTAssertNil(HookCapture.statusInfo(sessionId: "s"))
    }

    // MARK: - Effort reader

    func testLatestEffortFromEvents() throws {
        try writeEvents([
            hookEvent("PostToolUse", tool: "Bash"),
            ["hook_event_name": "PermissionRequest", "session_id": "s",
             "effort": ["level": "xhigh"], "tool_name": "Bash", "tool_input": [:]],
        ])
        XCTAssertEqual(HookCapture.latestEffort(sessionId: "s"), "xhigh")
        XCTAssertNil(HookCapture.latestEffort(sessionId: "none"))
    }

    // MARK: - Installer safety

    func testInstallMergesWithoutClobbering() throws {
        _ = try home.writeJSON(".claude/settings.json", [
            "model": "opus[1m]", "theme": "dark",
            "hooks": ["PreToolUse": [[
                "matcher": "Bash",
                "hooks": [["type": "command", "command": "my-own-hook.sh"]],
            ]]],
        ])
        try HookCapture.install()

        let data = try Data(contentsOf: ClaudePaths.userSettings)
        let settings = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(settings["model"] as? String, "opus[1m]", "foreign keys preserved")
        XCTAssertEqual(settings["theme"] as? String, "dark")
        let pre = (settings["hooks"] as! [String: Any])["PreToolUse"] as! [[String: Any]]
        XCTAssertEqual(pre.count, 2, "island entry added beside the user's own")
        XCTAssertTrue(HookCapture.isInstalled)
        XCTAssertTrue(HookCapture.isClickToAnswerInstalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: HookCapture.scriptURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: HookCapture.answerPythonURL.path))
        // Backup of the pre-install settings exists.
        XCTAssertTrue(FileManager.default.fileExists(atPath: HookCapture.settingsBackupURL.path))
    }

    func testInstallIsIdempotent() throws {
        _ = try home.writeJSON(".claude/settings.json", [:])
        try HookCapture.install()
        try HookCapture.install()
        let data = try Data(contentsOf: ClaudePaths.userSettings)
        let settings = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let permission = (settings["hooks"] as! [String: Any])["PermissionRequest"] as! [[String: Any]]
        XCTAssertEqual(permission.count, 2, "logger + answerer, not duplicated")
    }

    func testInstallRefusesCorruptSettings() throws {
        _ = try home.write(".claude/settings.json", "{ this is not json")
        XCTAssertThrowsError(try HookCapture.install(),
                             "merging into an unparseable file would destroy it")
        let contents = try String(contentsOf: ClaudePaths.userSettings, encoding: .utf8)
        XCTAssertEqual(contents, "{ this is not json", "file untouched on refusal")
    }

    func testStatusLineClaimedOnlyWhenAbsent() throws {
        _ = try home.writeJSON(".claude/settings.json", [
            "statusLine": ["type": "command", "command": "my-statusline.sh"],
        ])
        try HookCapture.install()
        let data = try Data(contentsOf: ClaudePaths.userSettings)
        let settings = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let statusLine = settings["statusLine"] as! [String: Any]
        XCTAssertEqual(statusLine["command"] as? String, "my-statusline.sh",
                       "a user's own statusline must never be clobbered")
    }

    func testUninstallRemovesOnlyIslandEntries() throws {
        _ = try home.writeJSON(".claude/settings.json", [
            "model": "opus[1m]",
            "hooks": ["PreToolUse": [[
                "matcher": "Bash",
                "hooks": [["type": "command", "command": "my-own-hook.sh"]],
            ]]],
        ])
        try HookCapture.install()
        try HookCapture.uninstall()

        let data = try Data(contentsOf: ClaudePaths.userSettings)
        let settings = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(settings["model"] as? String, "opus[1m]")
        let hooks = settings["hooks"] as! [String: Any]
        let pre = hooks["PreToolUse"] as! [[String: Any]]
        XCTAssertEqual(pre.count, 1, "the user's hook survives")
        XCTAssertNil(hooks["PermissionRequest"], "emptied events removed entirely")
        XCTAssertNil(settings["statusLine"] ?? nil, "our statusline removed")
        XCTAssertFalse(HookCapture.isInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: HookCapture.scriptURL.path))
    }

    // MARK: - App-side writers

    func testAppendClearMarker() throws {
        try HookCapture.install() // marker only writes when capture is active
        try writeEvents([hookEvent("PermissionRequest", tool: "Bash", input: ["command": "x"])])
        HookCapture.appendClearMarker(sessionId: "s")
        guard case .resolved? = latest() else {
            return XCTFail("clear marker must resolve the phantom dialog")
        }
    }

    func testWriteAnswerFile() throws {
        HookCapture.writeAnswer(sessionId: "s", answers: [
            (question: String(repeating: "q", count: 500), value: "A, B"),
            (question: "Second?", value: "free text answer"),
        ], promptId: "prompt-uuid-1")
        let url = HookCapture.answersDir.appendingPathComponent("s").appendingPathExtension("json")
        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let entries = payload["answers"] as! [[String: Any]]
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual((entries[0]["question_prefix"] as! String).count, 200, "prefix capped")
        XCTAssertEqual(entries[0]["value"] as? String, "A, B")
        XCTAssertEqual(entries[1]["value"] as? String, "free text answer")
        XCTAssertEqual(payload["prompt_id"] as? String, "prompt-uuid-1", "answer bound to its prompt")
    }

    // MARK: - Hardening: prompt-id binding & session-id validation

    func testPromptIdSurfacedFromPermissionRequest() throws {
        try writeEvents([
            hookEvent("PermissionRequest", tool: "AskUserQuestion",
                      input: askInput(), promptId: "pid-42"),
        ])
        guard case .pending(_, _, let promptId, _)? = latest() else { return XCTFail("expected pending") }
        XCTAssertEqual(promptId, "pid-42", "the dialog's prompt_id reaches the answer path")
    }

    func testSessionIdValidationRejectsTraversal() {
        XCTAssertTrue(HookCapture.isSafeSessionId("ecad31ca-be9b-439f-a5e3-2aaded71c3f4"))
        XCTAssertTrue(HookCapture.isSafeSessionId("job_1234-ABC"))
        for bad in ["../evil", "a/b", "..", "with space", "", "tab\t",
                    "dot.dot", String(repeating: "x", count: 200)] {
            XCTAssertFalse(HookCapture.isSafeSessionId(bad), "must reject \(bad.debugDescription)")
        }
    }

    func testWriteAnswerRefusesUnsafeSessionId() {
        HookCapture.writeAnswer(sessionId: "../escape", answers: [(question: "Q", value: "V")])
        // Nothing may be written outside (or inside) the answers dir for a
        // path-traversing id.
        let escaped = HookCapture.answersDir.deletingLastPathComponent()
            .appendingPathComponent("escape.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path))
        XCTAssertNil(HookCapture.latestState(sessionId: "../escape", notBefore: nil))
    }

    func testInstalledIslandDirIsOwnerOnly() throws {
        _ = try home.writeJSON(".claude/settings.json", [:])
        try HookCapture.install()
        let attrs = try FileManager.default.attributesOfItem(atPath: HookCapture.answersDir.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms & 0o077, 0, "group/other must have no access to answers dir")
    }

    func testPruneStaleFiles() throws {
        try writeEvents([hookEvent("Stop")], sessionId: "old")
        try writeEvents([hookEvent("Stop")], sessionId: "new")
        // The sweep also covers status payloads (the cwd fallback scans that
        // whole directory, so leftovers have a per-poll cost) and answers.
        _ = try home.writeJSON(".claude/island/status/old.json", ["session_id": "old"])
        _ = try home.writeJSON(".claude/island/answers/old.json", ["answers": []])
        let stale = Date(timeIntervalSinceNow: -8 * 24 * 3600)
        for path in [".claude/island/events/old.jsonl",
                     ".claude/island/status/old.json",
                     ".claude/island/answers/old.json"] {
            try home.setModificationDate(path, stale)
        }
        HookCapture.pruneStaleFiles()
        let files = try FileManager.default.contentsOfDirectory(atPath: HookCapture.eventsDir.path)
        XCTAssertEqual(Set(files), ["new.jsonl"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: HookCapture.statusDir.appendingPathComponent("old.json").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: HookCapture.answersDir.appendingPathComponent("old.json").path))
    }

    // MARK: - Permission click-to-answer plumbing

    func testSuggestionsSurfacedFromPermissionRequest() throws {
        try writeEvents([
            hookEvent("PermissionRequest", tool: "WebFetch",
                      input: ["url": "https://api.github.com/x"],
                      suggestions: [domainSuggestion()]),
        ])
        guard case .pending(let tool, _, _, let suggestions)? = latest() else {
            return XCTFail("expected pending")
        }
        XCTAssertEqual(tool, "WebFetch")
        XCTAssertEqual(suggestions.count, 1)
        let rules = suggestions.first?["rules"] as? [[String: Any]]
        XCTAssertEqual(rules?.first?["ruleContent"] as? String, "domain:api.github.com")
    }

    func testSuggestionsBackfilledOntoDedupedDialog() throws {
        // PreToolUse (no suggestions) then PermissionRequest (with them) for
        // the same dialog: one pending entry, suggestions kept.
        let input = askInput()
        try writeEvents([
            hookEvent("PreToolUse", tool: "AskUserQuestion", input: input, toolUseId: "t1"),
            hookEvent("PermissionRequest", tool: "AskUserQuestion", input: input,
                      suggestions: [domainSuggestion("x.dev", tool: "AskUserQuestion")]),
        ])
        guard case .pending(_, _, _, let suggestions)? = latest() else {
            return XCTFail("expected pending")
        }
        XCTAssertEqual(suggestions.count, 1, "merge must not drop the richer event's suggestions")
    }

    func testWritePermissionAnswerFile() throws {
        HookCapture.writePermissionAnswer(
            sessionId: "s",
            toolName: "WebFetch",
            inputSignature: ["url": "https://api.github.com/x"],
            decision: .allowAlways,
            message: nil,
            promptId: "pid-7"
        )
        let url = HookCapture.answersDir.appendingPathComponent("s").appendingPathExtension("json")
        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let permission = payload["permission"] as! [String: Any]
        XCTAssertEqual(permission["tool_name"] as? String, "WebFetch")
        XCTAssertEqual(permission["decision"] as? String, "allow_always")
        XCTAssertEqual((permission["input_sig"] as? [String: String])?["url"], "https://api.github.com/x")
        XCTAssertNil(permission["message"], "no feedback key unless one was typed")
        XCTAssertEqual(payload["prompt_id"] as? String, "pid-7")

        HookCapture.writePermissionAnswer(
            sessionId: "s", toolName: "Bash", inputSignature: [:],
            decision: .deny, message: "use ripgrep instead"
        )
        let denyPayload = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let deny = denyPayload["permission"] as! [String: Any]
        XCTAssertEqual(deny["decision"] as? String, "deny")
        XCTAssertEqual(deny["message"] as? String, "use ripgrep instead")
    }

    func testInstallWritesMatcherlessAnswerHook() throws {
        _ = try home.writeJSON(".claude/settings.json", [:])
        try HookCapture.install()
        let settings = try JSONSerialization.jsonObject(
            with: Data(contentsOf: ClaudePaths.userSettings)) as! [String: Any]
        let entries = (settings["hooks"] as! [String: Any])["PermissionRequest"] as! [[String: Any]]
        let answer = entries.first { entry in
            ((entry["hooks"] as? [[String: Any]]) ?? []).contains {
                ($0["command"] as? String)?.contains("answer.sh") == true
            }
        }
        XCTAssertNotNil(answer, "answer hook installed")
        XCTAssertNil(answer?["matcher"], "no matcher — it must race every tool's dialog")
    }

}
