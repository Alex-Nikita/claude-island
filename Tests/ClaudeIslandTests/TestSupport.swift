import Foundation
import XCTest
@testable import ClaudeIsland

// A throwaway ~ replacement so no test ever touches the real ~/.claude.
// Tests run serially in-process by default; the override is process-global,
// so every filesystem test installs it in setUp and clears it in tearDown.
final class FixtureHome {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        ClaudePaths.overrideHome = root
    }

    func tearDown() {
        ClaudePaths.overrideHome = nil
        try? FileManager.default.removeItem(at: root)
    }

    var claudeDir: URL { root.appendingPathComponent(".claude") }

    func mkdir(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func write(_ relative: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func writeJSON(_ relative: String, _ object: [String: Any]) throws -> URL {
        let data = try JSONSerialization.data(withJSONObject: object)
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url)
        return url
    }

    func writeLines(_ relative: String, _ objects: [[String: Any]]) throws -> URL {
        let lines = try objects.map { object -> String in
            let data = try JSONSerialization.data(withJSONObject: object)
            return String(data: data, encoding: .utf8)!
        }
        return try write(relative, lines.joined(separator: "\n") + "\n")
    }

    func setModificationDate(_ relative: String, _ date: Date) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: root.appendingPathComponent(relative).path
        )
    }
}

// MARK: - Transcript line builders

func assistantLine(
    toolUse name: String? = nil,
    toolUseId: String = "toolu_test",
    input: [String: Any] = [:],
    usage: [String: Any]? = nil,
    model: String = "claude-fable-5",
    sidechain: Bool = false
) -> [String: Any] {
    var content: [[String: Any]] = []
    if let name {
        content.append(["type": "tool_use", "id": toolUseId, "name": name, "input": input])
    }
    var message: [String: Any] = ["role": "assistant", "content": content, "model": model]
    if let usage { message["usage"] = usage }
    return ["type": "assistant", "isSidechain": sidechain, "message": message]
}

func userTextLine(_ text: String) -> [String: Any] {
    ["type": "user", "message": ["role": "user", "content": text]]
}

func userBlockTextLine(_ text: String) -> [String: Any] {
    ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]]]
}

func toolResultLine(id: String, content: String = "done") -> [String: Any] {
    ["type": "user", "message": ["role": "user", "content": [
        ["type": "tool_result", "tool_use_id": id, "content": content]
    ]]]
}

func noiseLine(_ type: String = "attachment") -> [String: Any] {
    [
        "type": type,
        "attachment": ["type": "noise", "padding": String(repeating: "x", count: 64)],
    ]
}

// MARK: - Hook event builders

func hookEvent(_ name: String, tool: String? = nil, input: [String: Any]? = nil,
               toolUseId: String? = nil, message: String? = nil,
               promptId: String? = nil, suggestions: [[String: Any]]? = nil) -> [String: Any] {
    var event: [String: Any] = ["hook_event_name": name, "session_id": "s"]
    if let tool { event["tool_name"] = tool }
    if let input { event["tool_input"] = input }
    if let toolUseId { event["tool_use_id"] = toolUseId }
    if let message { event["message"] = message }
    if let promptId { event["prompt_id"] = promptId }
    if let suggestions { event["permission_suggestions"] = suggestions }
    return event
}

// A real captured WebFetch suggestion shape (Claude Code 2.1.217).
func domainSuggestion(_ host: String = "api.github.com", tool: String = "WebFetch") -> [String: Any] {
    ["type": "addRules", "destination": "localSettings", "behavior": "allow",
     "rules": [["toolName": tool, "ruleContent": "domain:\(host)"]]]
}

func askInput(question: String = "Pick?", options: [String] = ["A", "B"],
              multiSelect: Bool = false) -> [String: Any] {
    ["questions": [[
        "question": question,
        "header": "H",
        "options": options.map { ["label": $0] },
        "multiSelect": multiSelect,
    ]]]
}
