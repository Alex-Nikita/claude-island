import XCTest
@testable import ClaudeIsland

// The shell/python helpers Claude Code executes are part of the product;
// exercise the REAL files install() writes, in a fixture HOME.
final class ScriptTests: XCTestCase {
    private var home: FixtureHome!

    override func setUpWithError() throws {
        home = try FixtureHome()
        _ = try home.writeJSON(".claude/settings.json", [:])
        try HookCapture.install()
    }

    override func tearDown() {
        home.tearDown()
        home = nil
    }

    @discardableResult
    private func run(_ url: URL, args: [String] = [], stdin: String) throws -> (out: String, status: Int32) {
        let process = Process()
        process.executableURL = url
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.root.path
        process.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = Pipe()
        try process.run()
        inPipe.fileHandleForWriting.write(stdin.data(using: .utf8)!)
        inPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (out, process.terminationStatus)
    }

    private func eventLines(_ sessionId: String) throws -> [[String: Any]] {
        let url = HookCapture.eventsDir.appendingPathComponent(sessionId).appendingPathExtension("jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    private let sid = "aaaa1111-2222-3333-4444-555566667777"

    // MARK: - capture.sh

    func testCaptureFullMode() throws {
        let payload = #"{"session_id":"\#(sid)","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[]}}"#
        let result = try run(HookCapture.scriptURL, stdin: payload)
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.out.isEmpty, "capture must never write to stdout")
        let lines = try eventLines(sid)
        XCTAssertEqual(lines.first?["hook_event_name"] as? String, "PreToolUse")
    }

    func testCaptureMarkerMode() throws {
        let payload = #"{"session_id":"\#(sid)","hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"huge":"data"},"tool_use_id":"toolu_01AbC"}"#
        _ = try run(HookCapture.scriptURL, args: ["marker", "PostToolUse"], stdin: payload)
        let line = try XCTUnwrap(eventLines(sid).first)
        XCTAssertEqual(line["hook_event_name"] as? String, "PostToolUse")
        XCTAssertEqual(line["tool_use_id"] as? String, "toolu_01AbC")
        XCTAssertEqual(line["tool_name"] as? String, "Bash")
        XCTAssertNil(line["tool_response"], "markers are tiny — no payload passthrough")
    }

    func testEmbeddedSessionIdCannotHijackFilename() throws {
        let payload = #"{"session_id":"\#(sid)","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"echo \"session_id\" nonsense"}}"#
        _ = try run(HookCapture.scriptURL, stdin: payload)
        XCTAssertNoThrow(try eventLines(sid), "the top-level id wins")
    }

    func testMissingSessionIdFallsBackToUnknown() throws {
        _ = try run(HookCapture.scriptURL, stdin: #"{"hook_event_name":"Stop"}"#)
        XCTAssertNoThrow(try eventLines("unknown"))
    }

    // MARK: - statusline.sh

    func testStatuslineSavesPayloadAndRendersLine() throws {
        let payload = #"{"session_id":"\#(sid)","model":{"id":"claude-fable-5","display_name":"Fable 5"},"workspace":{"current_dir":"/Users/x/claude-island"},"context_window":{"context_window_size":1000000,"used_percentage":57.4}}"#
        let result = try run(HookCapture.statusScriptURL, stdin: payload)
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.out.contains("claude-island"))
        XCTAssertTrue(result.out.contains("Fable 5"))
        XCTAssertTrue(result.out.contains("57% context"))
        let saved = HookCapture.statusDir.appendingPathComponent(sid).appendingPathExtension("json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    }

    // MARK: - answer.py (requires python3)

    private var python3Available: Bool {
        FileManager.default.fileExists(atPath: "/usr/bin/python3")
    }

    private func answerPayload(question: String = "Which color?",
                               sessionId: String? = nil, promptId: String? = nil) -> String {
        let sess = sessionId ?? sid
        let pid = promptId.map { #""prompt_id":"\#($0)","# } ?? ""
        return #"{\#(pid)"session_id":"\#(sess)","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"\#(question)","header":"H","options":[{"label":"Blue"},{"label":"Red"}],"multiSelect":false}]}}"#
    }

    private func runAnswerHook(stdin: String, beforehand: (() throws -> Void)? = nil,
                               delayedClick: [String: Any]? = nil) throws -> String {
        try beforehand?()
        if let delayedClick {
            let dir = HookCapture.answersDir
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { [sid] in
                let data = try! JSONSerialization.data(withJSONObject: delayedClick)
                try! data.write(to: dir.appendingPathComponent(sid).appendingPathExtension("json"))
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [HookCapture.answerPythonURL.path]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.root.path
        // Cap the poll loop so a missed signal fails in seconds, not 290s.
        env["ISLAND_ANSWER_DEADLINE"] = "20"
        process.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        inPipe.fileHandleForWriting.write(stdin.data(using: .utf8)!)
        inPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        return String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    func testAnswerHookSubmitsIslandClick() throws {
        try XCTSkipUnless(python3Available)
        let out = try runAnswerHook(
            stdin: answerPayload(),
            delayedClick: ["answers": [["question_prefix": "Which color?", "value": "Blue"]]]
        )
        let decision = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        )
        let specific = decision["hookSpecificOutput"] as? [String: Any]
        let inner = specific?["decision"] as? [String: Any]
        XCTAssertEqual(inner?["behavior"] as? String, "allow")
        let updated = inner?["updatedInput"] as? [String: Any]
        XCTAssertEqual((updated?["answers"] as? [String: String])?["Which color?"], "Blue")
        XCTAssertNotNil(updated?["questions"], "questions must be echoed verbatim")
    }

    func testAnswerHookExitsQuietlyWhenTerminalWins() throws {
        try XCTSkipUnless(python3Available)
        // A PostToolUse marker appended after start signals the terminal won.
        let events = HookCapture.eventsDir.appendingPathComponent(sid).appendingPathExtension("jsonl")
        try FileManager.default.createDirectory(at: HookCapture.eventsDir, withIntermediateDirectories: true)
        try "".write(to: events, atomically: true, encoding: .utf8)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) {
            let marker = #"{"hook_event_name":"PostToolUse","session_id":"x","tool_name":"AskUserQuestion"}"# + "\n"
            if let handle = try? FileHandle(forWritingTo: events) {
                handle.seekToEndOfFile()
                handle.write(marker.data(using: .utf8)!)
                try? handle.close()
            }
        }
        let start = Date()
        let out = try runAnswerHook(stdin: answerPayload())
        XCTAssertTrue(out.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "must not poll to its deadline")
    }

    func testAnswerHookIgnoresSubagentContexts() throws {
        try XCTSkipUnless(python3Available)
        let payload = #"{"session_id":"\#(sid)","agent_id":"a1","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Q","header":"H","options":[{"label":"A"},{"label":"B"}]}]}}"#
        let start = Date()
        let out = try runAnswerHook(stdin: payload)
        XCTAssertTrue(out.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "must bail immediately")
    }

    func testAnswerHookMultiQuestionAndFreeText() throws {
        try XCTSkipUnless(python3Available)
        let payload = #"{"session_id":"\#(sid)","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Pick a color?","header":"A","options":[{"label":"Blue"},{"label":"Red"}],"multiSelect":false},{"question":"Any notes?","header":"B","options":[{"label":"None"},{"label":"Some"}],"multiSelect":false}]}}"#
        let out = try runAnswerHook(
            stdin: payload,
            delayedClick: ["answers": [
                ["question_prefix": "Pick a color?", "value": "Blue"],
                ["question_prefix": "Any notes?", "value": "shipped from the island, free text"],
            ]]
        )
        let decision = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        )
        let inner = (decision["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        let answers = (inner?["updatedInput"] as? [String: Any])?["answers"] as? [String: String]
        XCTAssertEqual(answers?["Pick a color?"], "Blue")
        XCTAssertEqual(answers?["Any notes?"], "shipped from the island, free text")
    }

    func testAnswerHookRequiresEveryQuestionAnswered() throws {
        try XCTSkipUnless(python3Available)
        // Two questions, one answer: must not submit a partial set.
        let payload = #"{"session_id":"\#(sid)","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Q1?","header":"A","options":[{"label":"X"},{"label":"Y"}]},{"question":"Q2?","header":"B","options":[{"label":"X"},{"label":"Y"}]}]}}"#
        let events = HookCapture.eventsDir.appendingPathComponent(sid).appendingPathExtension("jsonl")
        try FileManager.default.createDirectory(at: HookCapture.eventsDir, withIntermediateDirectories: true)
        try "".write(to: events, atomically: true, encoding: .utf8)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.4) {
            let marker = #"{"hook_event_name":"Stop","session_id":"x"}"# + "\n"
            if let handle = try? FileHandle(forWritingTo: events) {
                handle.seekToEndOfFile()
                handle.write(marker.data(using: .utf8)!)
                try? handle.close()
            }
        }
        let out = try runAnswerHook(
            stdin: payload,
            delayedClick: ["answers": [["question_prefix": "Q1?", "value": "X"]]]
        )
        XCTAssertTrue(out.isEmpty)
    }

    func testAnswerHookRejectsStaleAnswerForDifferentQuestion() throws {
        try XCTSkipUnless(python3Available)
        // Click for the WRONG question + terminal resolution shortly after:
        // the hook must not submit the mismatched answer.
        let events = HookCapture.eventsDir.appendingPathComponent(sid).appendingPathExtension("jsonl")
        try FileManager.default.createDirectory(at: HookCapture.eventsDir, withIntermediateDirectories: true)
        try "".write(to: events, atomically: true, encoding: .utf8)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) {
            let marker = #"{"hook_event_name":"Stop","session_id":"x"}"# + "\n"
            if let handle = try? FileHandle(forWritingTo: events) {
                handle.seekToEndOfFile()
                handle.write(marker.data(using: .utf8)!)
                try? handle.close()
            }
        }
        let out = try runAnswerHook(
            stdin: answerPayload(question: "Fresh question?"),
            delayedClick: ["answers": [["question_prefix": "Old question", "value": "Blue"]]]
        )
        XCTAssertTrue(out.isEmpty, "mismatched prefix must never produce a decision")
    }

    // MARK: - Hardening: prompt-id binding & session-id validation

    func testAnswerHookAcceptsMatchingPromptId() throws {
        try XCTSkipUnless(python3Available)
        let out = try runAnswerHook(
            stdin: answerPayload(promptId: "pid-live"),
            delayedClick: ["prompt_id": "pid-live",
                           "answers": [["question_prefix": "Which color?", "value": "Blue"]]]
        )
        let decision = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        )
        let inner = (decision["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        XCTAssertEqual(inner?["behavior"] as? String, "allow", "answer bound to the same prompt is accepted")
    }

    func testAnswerHookRejectsMismatchedPromptId() throws {
        try XCTSkipUnless(python3Available)
        // A planted/stale answer file naming a DIFFERENT dialog must never
        // answer this prompt, even though the question prefix matches.
        let events = HookCapture.eventsDir.appendingPathComponent(sid).appendingPathExtension("jsonl")
        try FileManager.default.createDirectory(at: HookCapture.eventsDir, withIntermediateDirectories: true)
        try "".write(to: events, atomically: true, encoding: .utf8)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) {
            let marker = #"{"hook_event_name":"Stop","session_id":"x"}"# + "\n"
            if let handle = try? FileHandle(forWritingTo: events) {
                handle.seekToEndOfFile()
                handle.write(marker.data(using: .utf8)!)
                try? handle.close()
            }
        }
        let out = try runAnswerHook(
            stdin: answerPayload(promptId: "pid-current"),
            delayedClick: ["prompt_id": "pid-OTHER",
                           "answers": [["question_prefix": "Which color?", "value": "Blue"]]]
        )
        XCTAssertTrue(out.isEmpty, "a wrong prompt_id must never produce a decision")
        // The file was NOT for us, so it must be left in place, not consumed.
        let clickFile = HookCapture.answersDir.appendingPathComponent(sid).appendingPathExtension("json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: clickFile.path),
                      "a mismatched file belongs to another dialog and must be left untouched")
    }

    func testAnswerHookRejectsTraversalSessionId() throws {
        try XCTSkipUnless(python3Available)
        let start = Date()
        let out = try runAnswerHook(stdin: answerPayload(sessionId: "../../etc/passwd"))
        XCTAssertTrue(out.isEmpty, "a path-traversing session id must be rejected outright")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "rejected before the poll loop")
    }

    // MARK: - answer.py: permission dialogs (all tools)

    private func webFetchPayload(suggestions: String = "") -> String {
        #"{"session_id":"\#(sid)","prompt_id":"pid-1","hook_event_name":"PermissionRequest","tool_name":"WebFetch","tool_input":{"url":"https://api.github.com/repos","prompt":"read"}\#(suggestions)}"#
    }

    private let domainSuggestionsJSON =
        #","permission_suggestions":[{"type":"addRules","destination":"localSettings","behavior":"allow","rules":[{"toolName":"WebFetch","ruleContent":"domain:api.github.com"}]}]"#

    private func permissionClick(_ decision: String, tool: String = "WebFetch",
                                 sig: [String: String] = ["url": "https://api.github.com/repos"],
                                 message: String? = nil) -> [String: Any] {
        var permission: [String: Any] = ["tool_name": tool, "input_sig": sig, "decision": decision]
        if let message { permission["message"] = message }
        return ["prompt_id": "pid-1", "permission": permission]
    }

    private func decisionJSON(_ out: String) throws -> [String: Any] {
        let decision = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        )
        return try XCTUnwrap(
            (decision["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        )
    }

    func testPermissionClickAllows() throws {
        try XCTSkipUnless(python3Available)
        let out = try runAnswerHook(stdin: webFetchPayload(),
                                    delayedClick: permissionClick("allow"))
        let inner = try decisionJSON(out)
        XCTAssertEqual(inner["behavior"] as? String, "allow")
        let updated = inner["updatedInput"] as? [String: Any]
        XCTAssertEqual(updated?["url"] as? String, "https://api.github.com/repos",
                       "input echoed verbatim, like the terminal's own Yes")
        XCTAssertNil(inner["updatedPermissions"], "plain allow persists nothing")
    }

    func testPermissionClickAllowAlwaysEchoesSuggestedRules() throws {
        try XCTSkipUnless(python3Available)
        let out = try runAnswerHook(stdin: webFetchPayload(suggestions: domainSuggestionsJSON),
                                    delayedClick: permissionClick("allow_always"))
        let inner = try decisionJSON(out)
        XCTAssertEqual(inner["behavior"] as? String, "allow")
        let updates = inner["updatedPermissions"] as? [[String: Any]]
        XCTAssertEqual(updates?.count, 1, "Claude Code's suggestions echoed verbatim")
        let rules = updates?.first?["rules"] as? [[String: Any]]
        XCTAssertEqual(rules?.first?["ruleContent"] as? String, "domain:api.github.com")
    }

    func testPermissionClickDeniesWithFeedback() throws {
        try XCTSkipUnless(python3Available)
        let out = try runAnswerHook(
            stdin: webFetchPayload(),
            delayedClick: permissionClick("deny", message: "use the local checkout instead")
        )
        let inner = try decisionJSON(out)
        XCTAssertEqual(inner["behavior"] as? String, "deny")
        XCTAssertEqual(inner["message"] as? String, "use the local checkout instead")

        // Empty feedback = plain deny with no message key at all.
        let plain = try runAnswerHook(stdin: webFetchPayload(),
                                      delayedClick: permissionClick("deny"))
        let plainInner = try decisionJSON(plain)
        XCTAssertEqual(plainInner["behavior"] as? String, "deny")
        XCTAssertNil(plainInner["message"])
    }

    func testPermissionClickForDifferentToolIsLeftForItsOwnRacer() throws {
        try XCTSkipUnless(python3Available)
        // Parallel dialogs each run their own hook. A click for another
        // tool's dialog must neither answer this one nor be consumed.
        let events = HookCapture.eventsDir.appendingPathComponent(sid).appendingPathExtension("jsonl")
        try FileManager.default.createDirectory(at: HookCapture.eventsDir, withIntermediateDirectories: true)
        try "".write(to: events, atomically: true, encoding: .utf8)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) {
            let marker = #"{"hook_event_name":"Stop","session_id":"x"}"# + "\n"
            if let handle = try? FileHandle(forWritingTo: events) {
                handle.seekToEndOfFile()
                handle.write(marker.data(using: .utf8)!)
                try? handle.close()
            }
        }
        let out = try runAnswerHook(
            stdin: webFetchPayload(),
            delayedClick: permissionClick("allow", tool: "Bash", sig: [:])
        )
        XCTAssertTrue(out.isEmpty, "tool mismatch must never produce a decision")
        let clickFile = HookCapture.answersDir.appendingPathComponent(sid).appendingPathExtension("json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: clickFile.path),
                      "the sibling dialog's racer still needs this file")
    }

    func testPermissionClickWithMismatchedInputIsIgnored() throws {
        try XCTSkipUnless(python3Available)
        // Same tool, same turn, different dialog content (the prompt_id is
        // per-turn, so the input fingerprint is what keeps siblings apart).
        let events = HookCapture.eventsDir.appendingPathComponent(sid).appendingPathExtension("jsonl")
        try FileManager.default.createDirectory(at: HookCapture.eventsDir, withIntermediateDirectories: true)
        try "".write(to: events, atomically: true, encoding: .utf8)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) {
            let marker = #"{"hook_event_name":"Stop","session_id":"x"}"# + "\n"
            if let handle = try? FileHandle(forWritingTo: events) {
                handle.seekToEndOfFile()
                handle.write(marker.data(using: .utf8)!)
                try? handle.close()
            }
        }
        let out = try runAnswerHook(
            stdin: webFetchPayload(),
            delayedClick: permissionClick("allow", sig: ["url": "https://evil.example/other"])
        )
        XCTAssertTrue(out.isEmpty, "an input-fingerprint mismatch must never allow")
    }

    func testAnswerHookSkipsExitPlanMode() throws {
        try XCTSkipUnless(python3Available)
        let payload = #"{"session_id":"\#(sid)","hook_event_name":"PermissionRequest","tool_name":"ExitPlanMode","tool_input":{"plan":"Step 1"}}"#
        let start = Date()
        let out = try runAnswerHook(stdin: payload)
        XCTAssertTrue(out.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3,
                          "plan approval stays display-only — no racer")
    }

    func testSiblingToolMarkerDoesNotEndTheRace() throws {
        try XCTSkipUnless(python3Available)
        // A parallel Bash sibling resolving must not kill the WebFetch racer:
        // its dialog is still on screen, and a click after the marker must
        // still win.
        let events = HookCapture.eventsDir.appendingPathComponent(sid).appendingPathExtension("jsonl")
        try FileManager.default.createDirectory(at: HookCapture.eventsDir, withIntermediateDirectories: true)
        try "".write(to: events, atomically: true, encoding: .utf8)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            let marker = #"{"hook_event_name":"PostToolUse","session_id":"x","tool_name":"Bash"}"# + "\n"
            if let handle = try? FileHandle(forWritingTo: events) {
                handle.seekToEndOfFile()
                handle.write(marker.data(using: .utf8)!)
                try? handle.close()
            }
        }
        let out = try runAnswerHook(stdin: webFetchPayload(),
                                    delayedClick: permissionClick("allow"))
        let inner = try decisionJSON(out)
        XCTAssertEqual(inner["behavior"] as? String, "allow",
                       "the race must survive a sibling tool's resolution marker")
    }

    func testOwnToolMarkerStillEndsTheRace() throws {
        try XCTSkipUnless(python3Available)
        let events = HookCapture.eventsDir.appendingPathComponent(sid).appendingPathExtension("jsonl")
        try FileManager.default.createDirectory(at: HookCapture.eventsDir, withIntermediateDirectories: true)
        try "".write(to: events, atomically: true, encoding: .utf8)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) {
            let marker = #"{"hook_event_name":"PostToolUse","session_id":"x","tool_name":"WebFetch"}"# + "\n"
            if let handle = try? FileHandle(forWritingTo: events) {
                handle.seekToEndOfFile()
                handle.write(marker.data(using: .utf8)!)
                try? handle.close()
            }
        }
        let start = Date()
        let out = try runAnswerHook(stdin: webFetchPayload())
        XCTAssertTrue(out.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10,
                          "answered in the terminal → the racer exits promptly")
    }
}
