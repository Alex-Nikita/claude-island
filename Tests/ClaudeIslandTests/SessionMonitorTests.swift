import XCTest
@testable import ClaudeIsland

final class SessionMonitorTests: XCTestCase {
    private var home: FixtureHome!
    private let monitor = SessionMonitor()

    override func setUpWithError() throws {
        home = try FixtureHome()
    }

    override func tearDown() {
        home.tearDown()
        home = nil
    }

    // MARK: - Path munging

    func testMungingMatchesClaudeCodeSemantics() {
        // Plain ASCII path.
        XCTAssertTrue(
            monitor.transcriptURL(cwd: "/Users/x/Documents/app", sessionId: "s").path
                .contains("/-Users-x-Documents-app/")
        )
        // Emoji is a UTF-16 surrogate pair: TWO dashes, matching Claude Code's
        // per-code-unit regex (verified against real output).
        XCTAssertTrue(
            monitor.transcriptURL(cwd: "/x/🚀app", sessionId: "s").path
                .contains("/-x---app/")
        )
        // BMP accents are single code units: one dash.
        XCTAssertTrue(
            monitor.transcriptURL(cwd: "/x/café", sessionId: "s").path
                .contains("/-x-caf-/")
        )
    }

    // MARK: - Runtime extraction

    private func writeTranscript(_ lines: [[String: Any]], cwd: String = "/tmp/proj",
                                 sessionId: String = "abc") throws {
        let url = monitor.transcriptURL(cwd: cwd, sessionId: sessionId)
        let relative = url.path.replacingOccurrences(of: home.root.path + "/", with: "")
        _ = try home.writeLines(relative, lines)
    }

    private func runtime(cwd: String = "/tmp/proj", sessionId: String = "abc")
        -> (model: String?, contextTokens: Double?, skills: [String]) {
        monitor.runtimeInfo(transcript: monitor.transcriptURL(cwd: cwd, sessionId: sessionId))
    }

    func testModelAndContextFromNewestUsageEntry() throws {
        try writeTranscript([
            assistantLine(usage: ["input_tokens": 1, "cache_read_input_tokens": 10,
                                  "cache_creation_input_tokens": 1], model: "claude-old"),
            assistantLine(usage: ["input_tokens": 2, "cache_read_input_tokens": 345_446,
                                  "cache_creation_input_tokens": 5_635], model: "claude-fable-5"),
        ])
        let info = runtime()
        XCTAssertEqual(info.model, "claude-fable-5")
        XCTAssertEqual(info.contextTokens, 351_083)
    }

    func testSidechainEntriesIgnored() throws {
        try writeTranscript([
            assistantLine(usage: ["input_tokens": 7], model: "claude-main"),
            assistantLine(usage: ["input_tokens": 999_999], model: "claude-side", sidechain: true),
        ])
        XCTAssertEqual(runtime().model, "claude-main")
    }

    func testSkillDetectionFromInjectedInstructions() throws {
        try writeTranscript([
            userTextLine("please do the thing"),                       // turn start
            assistantLine(toolUse: "Bash", toolUseId: "t1"),
            userBlockTextLine("Base directory for this skill: /tmp/skills/claude-api\n\n# Docs…"),
            assistantLine(usage: ["input_tokens": 5], model: "claude-fable-5"),
        ])
        XCTAssertEqual(runtime().skills, ["claude-api"])
    }

    func testSkillsResetAtRealUserPrompt() throws {
        try writeTranscript([
            userBlockTextLine("Base directory for this skill: /tmp/skills/old-skill\nstuff"),
            userTextLine("new prompt from the human"),                 // boundary
            assistantLine(usage: ["input_tokens": 5]),
        ])
        XCTAssertEqual(runtime().skills, [], "skills from previous turns are not in use")
    }

    func testInjectedMessagesAreNotTurnBoundaries() throws {
        try writeTranscript([
            userTextLine("real prompt"),
            userBlockTextLine("Base directory for this skill: /tmp/skills/mid-turn-skill\nx"),
            userTextLine("[Request interrupted by user]"),
            userBlockTextLine("<command-name>/context</command-name>"),
            assistantLine(usage: ["input_tokens": 5]),
        ])
        // The skill stays despite the interrupt note and command tag after it.
        XCTAssertEqual(runtime().skills, ["mid-turn-skill"])
    }

    // MARK: - Context limit inference

    func testObservedContextProvesLargeWindow() {
        XCTAssertEqual(
            SessionMonitor.contextLimit(model: "claude-fable-5", contextTokens: 351_083,
                                        settingsModel: "opus[1m]"),
            1_000_000, "context beyond 190k is proof of a 1M window regardless of alias"
        )
    }

    func testAliasFamilyMatchBelowThreshold() {
        XCTAssertEqual(
            SessionMonitor.contextLimit(model: "claude-fable-5", contextTokens: 50_000,
                                        settingsModel: "claude-fable-5[1m]"),
            1_000_000
        )
        XCTAssertEqual(
            SessionMonitor.contextLimit(model: "claude-fable-5", contextTokens: 50_000,
                                        settingsModel: "opus[1m]"),
            200_000, "different family alias must not widen the window"
        )
        XCTAssertEqual(
            SessionMonitor.contextLimit(model: "claude-fable-5", contextTokens: 50_000,
                                        settingsModel: "sonnet"),
            200_000
        )
        XCTAssertNil(SessionMonitor.contextLimit(model: nil, contextTokens: nil, settingsModel: ""))
    }

    // MARK: - Transcript pending fallback

    private func pending(_ lines: [[String: Any]]) throws -> PendingPrompt? {
        try writeTranscript(lines)
        return monitor.transcriptPendingPrompt(
            in: monitor.transcriptURL(cwd: "/tmp/proj", sessionId: "abc")
        )
    }

    func testFlushedQuestionIsExtracted() throws {
        let prompt = try pending([
            userTextLine("go"),
            assistantLine(toolUse: "AskUserQuestion", toolUseId: "q1",
                          input: askInput(question: "Which color?", options: ["Red", "Blue"])),
            noiseLine(),
        ])
        XCTAssertEqual(prompt?.title, "H")
        XCTAssertEqual(prompt?.detail, "Which color?")
        XCTAssertEqual(prompt?.options, ["Red", "Blue"])
        XCTAssertTrue(prompt?.answerable ?? false)
    }

    func testResolvedQuestionYieldsNil() throws {
        let prompt = try pending([
            assistantLine(toolUse: "AskUserQuestion", toolUseId: "q1", input: askInput()),
            toolResultLine(id: "q1", content: "answered"),
        ])
        XCTAssertNil(prompt)
    }

    func testUnresolvedNonBlockingToolIsNotAPrompt() throws {
        // The stale-parallel-sibling class of bug: an in-flight Bash must
        // never render as a permission prompt.
        let prompt = try pending([
            assistantLine(toolUse: "Bash", toolUseId: "b1", input: ["command": "sleep 99"]),
        ])
        XCTAssertNil(prompt)
    }

    // MARK: - buildPrompt

    func testBuildPromptVariants() {
        let ask = monitor.buildPrompt(name: "AskUserQuestion", input: askInput(multiSelect: true))
        XCTAssertTrue(ask.isMultiSelect)
        XCTAssertTrue(ask.answerable)
        XCTAssertEqual(ask.extraQuestionCount, 0)

        var multi = askInput()
        var questions = multi["questions"] as! [[String: Any]]
        questions.append(questions[0])
        multi["questions"] = questions
        let twoQ = monitor.buildPrompt(name: "AskUserQuestion", input: multi)
        XCTAssertEqual(twoQ.extraQuestionCount, 1)
        XCTAssertTrue(twoQ.answerable, "the stepper answers multi-question prompts")
        XCTAssertEqual(twoQ.allQuestions.count, 2)

        let plan = monitor.buildPrompt(name: "ExitPlanMode", input: ["plan": "Step 1"])
        XCTAssertEqual(plan.title, "Plan approval")
        XCTAssertEqual(plan.detail, "Step 1")

        let bash = monitor.buildPrompt(name: "Bash", input: ["command": "rm -rf /", "description": "boom"])
        XCTAssertTrue(bash.detail.contains("boom"))
        XCTAssertTrue(bash.detail.contains("rm -rf /"))
        XCTAssertEqual(bash.options, ["Yes", SessionMonitor.permissionDenyLabel],
                       "no suggestions → just the Yes and No rows")
        XCTAssertTrue(bash.answerable, "permission prompts are clickable")
        XCTAssertTrue(bash.isPermission)
        XCTAssertEqual(bash.allQuestions.count, 1, "one synthetic question drives the wizard")
        XCTAssertTrue(bash.allQuestions[0].question.contains("Do you want to proceed?"))
        XCTAssertEqual(bash.permissionChoices.map(\.decision), [.allow, .deny])

        let long = monitor.buildPrompt(
            name: "AskUserQuestion",
            input: askInput(question: String(repeating: "q", count: 2000))
        )
        XCTAssertLessThanOrEqual(long.detail.count, 701, "pathological questions are clipped")
    }

    // MARK: - Permission options mirror the terminal dialog

    func testWebFetchDomainSuggestionOptions() {
        let prompt = monitor.buildPrompt(
            name: "WebFetch",
            input: ["url": "https://api.github.com/repos", "prompt": "read it"],
            suggestions: [domainSuggestion()]
        )
        XCTAssertEqual(prompt.options, [
            "Yes",
            "Yes, and don't ask again for api.github.com",
            SessionMonitor.permissionDenyLabel,
        ])
        XCTAssertEqual(prompt.permissionChoices.map(\.decision), [.allow, .allowAlways, .deny])
        XCTAssertTrue(prompt.allQuestions[0].question
            .contains("Do you want to allow Claude to fetch this content?"))
        XCTAssertTrue(prompt.allQuestions[0].question.contains("https://api.github.com/repos"))
        XCTAssertEqual(prompt.inputSignature["url"], "https://api.github.com/repos",
                       "signature carries the displayed input")
    }

    func testAlwaysAllowLabelVariants() {
        func label(_ tool: String, _ suggestions: [[String: Any]], cwd: String = "/tmp/proj") -> String? {
            SessionMonitor.alwaysAllowLabel(toolName: tool, suggestions: suggestions, cwd: cwd)
        }
        // Whole-tool rule (real WebSearch capture shape).
        XCTAssertEqual(
            label("WebSearch", [["type": "addRules", "behavior": "allow",
                                 "destination": "localSettings",
                                 "rules": [["toolName": "WebSearch"]]]]),
            "Yes, and don't ask again for WebSearch"
        )
        // Bash prefix rule → "commands in <dir>".
        XCTAssertEqual(
            label("Bash", [["type": "addRules", "behavior": "allow",
                            "destination": "localSettings",
                            "rules": [["toolName": "Bash", "ruleContent": "git status:*"]]]]),
            "Yes, and don't ask again for git status commands in /tmp/proj"
        )
        // Bash exact-command rule (real capture shape).
        XCTAssertEqual(
            label("Bash", [["type": "addRules", "behavior": "allow",
                            "destination": "localSettings",
                            "rules": [["toolName": "Bash", "ruleContent": "make test"]]]]),
            "Yes, and don't ask again for make test"
        )
        // File-edit dialogs suggest a session mode (real capture shape).
        XCTAssertEqual(
            label("Edit", [["type": "setMode", "mode": "acceptEdits", "destination": "session"]]),
            "Yes, allow all edits during this session"
        )
        // Directory grants.
        XCTAssertEqual(
            label("Read", [["type": "addDirectories", "destination": "localSettings",
                            "directories": ["/tmp/data"]]]),
            "Yes, and always allow access to /tmp/data from this project"
        )
        // Multiple heterogeneous rules → the count fallback.
        XCTAssertEqual(
            label("Bash", [["type": "addRules", "behavior": "allow",
                            "destination": "localSettings",
                            "rules": [["toolName": "Bash", "ruleContent": "git status:*"],
                                      ["toolName": "Read", "ruleContent": "src/**"]]]]),
            "Yes, and add 2 suggested permission rules"
        )
        // No suggestions → no middle row at all.
        XCTAssertNil(label("Bash", []))
        // Home-relative display.
        let home = ClaudePaths.home.path
        XCTAssertEqual(
            label("Bash", [["type": "addRules", "behavior": "allow",
                            "destination": "localSettings",
                            "rules": [["toolName": "Bash", "ruleContent": "ls:*"]]]],
                  cwd: home + "/Documents/app"),
            "Yes, and don't ask again for ls commands in ~/Documents/app"
        )
    }

    func testInputSignatureStringKeysOnly() {
        let signature = SessionMonitor.inputSignature(of: [
            "command": "echo hi",
            "timeout": 5000,
            "description": String(repeating: "d", count: 400),
            "empty": "",
        ])
        XCTAssertEqual(signature["command"], "echo hi")
        XCTAssertNil(signature["timeout"], "non-string values are skipped")
        XCTAssertNil(signature["empty"], "empty strings prove nothing")
        XCTAssertEqual(signature["description"]?.count, 160, "prefixes are capped")
    }

    // MARK: - Runtime cache

    func testRuntimeInfoCacheKeyedOnMtime() throws {
        try writeTranscript([assistantLine(usage: ["input_tokens": 5], model: "claude-a")])
        let url = monitor.transcriptURL(cwd: "/tmp/proj", sessionId: "abc")
        let relative = url.path.replacingOccurrences(of: home.root.path + "/", with: "")
        let mtime = Date(timeIntervalSinceNow: -100)
        try home.setModificationDate(relative, mtime)
        XCTAssertEqual(monitor.runtimeInfo(transcript: url, mtime: mtime).model, "claude-a")

        // Rewrite the file but pin the same mtime: the cache must serve.
        try writeTranscript([assistantLine(usage: ["input_tokens": 5], model: "claude-b")])
        try home.setModificationDate(relative, mtime)
        XCTAssertEqual(monitor.runtimeInfo(transcript: url, mtime: mtime).model, "claude-a",
                       "same mtime serves the cached parse")

        // A changed mtime re-parses.
        let bumped = mtime.addingTimeInterval(60)
        try home.setModificationDate(relative, bumped)
        XCTAssertEqual(monitor.runtimeInfo(transcript: url, mtime: bumped).model, "claude-b",
                       "changed mtime invalidates the cache")

        // No mtime → uncached path always parses fresh.
        XCTAssertEqual(monitor.runtimeInfo(transcript: url).model, "claude-b")
    }

    // MARK: - Running agents

    func testRunningAgentsDetectedByFreshTranscripts() throws {
        let dir = ".claude/projects/-tmp-proj/abc/subagents"
        _ = try home.write("\(dir)/agent-a1.jsonl", "{}\n")
        _ = try home.writeJSON("\(dir)/agent-a1.meta.json",
                               ["agentType": "Explore", "description": "look around"])
        _ = try home.write("\(dir)/agent-a2.jsonl", "{}\n")
        _ = try home.writeJSON("\(dir)/agent-a2.meta.json", ["agentType": "code-reviewer"])
        try home.setModificationDate("\(dir)/agent-a2.jsonl", Date(timeIntervalSinceNow: -600))

        let sessionDir = home.root.appendingPathComponent(".claude/projects/-tmp-proj/abc")
        let agents = monitor.runningAgents(sessionDir: sessionDir)
        XCTAssertEqual(agents.map(\.type), ["Explore"], "stale transcripts are not running")
        XCTAssertEqual(agents.first?.detail, "look around")
    }

    // MARK: - Registry filtering

    private func writeRegistryEntry(sessionId: String, kind: String?, status: String,
                                    pid: Int = Int(getpid())) throws {
        var entry: [String: Any] = [
            "pid": pid, "sessionId": sessionId, "cwd": "/tmp/proj",
            "name": sessionId, "status": status,
            "updatedAt": Date().timeIntervalSince1970 * 1000,
            "statusUpdatedAt": Date().timeIntervalSince1970 * 1000,
            "startedAt": Date().timeIntervalSince1970 * 1000,
        ]
        if let kind { entry["kind"] = kind }
        _ = try home.writeJSON(".claude/sessions/\(sessionId).json", entry)
    }

    func testIdleBackgroundEntriesAreFiltered() throws {
        // The bg-spare ghost: a finished session's registry file whose pid
        // lives on in Claude Code's spare pool. Live pid, kind "bg", idle —
        // must not render as a session.
        try writeRegistryEntry(sessionId: "spare", kind: "bg", status: "idle")
        try writeRegistryEntry(sessionId: "real", kind: "interactive", status: "idle")
        try writeRegistryEntry(sessionId: "legacy", kind: nil, status: "idle")
        XCTAssertEqual(monitor.loadActiveSessions().map(\.id).sorted(), ["legacy", "real"],
                       "idle bg entries are pool residue; interactive and unmarked stay")
    }

    func testWorkingBackgroundJobStillShows() throws {
        // A background job that is genuinely busy (fresh registry claim, no
        // contradicting transcript) is worth a row while it runs.
        try writeRegistryEntry(sessionId: "bgjob", kind: "bg", status: "busy")
        XCTAssertEqual(monitor.loadActiveSessions().map(\.id), ["bgjob"])
    }

    func testDeadPidIsFiltered() throws {
        try writeRegistryEntry(sessionId: "gone", kind: "interactive", status: "idle",
                               pid: 99_999_999)
        XCTAssertTrue(monitor.loadActiveSessions().isEmpty)
    }

    // MARK: - Process identity

    func testProcessStartTimeSanity() {
        let start = SessionMonitor.processStartTime(pid: Int(getpid()))
        XCTAssertNotNil(start)
        XCTAssertLessThan(start!, Date(), "our own process started in the past")
        XCTAssertNil(SessionMonitor.processStartTime(pid: 99_999_999))
    }
}
