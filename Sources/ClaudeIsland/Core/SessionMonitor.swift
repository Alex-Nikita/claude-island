import Foundation
import Darwin

final class SessionMonitor {
    // A live pid that started this much later than the registry entry is a
    // recycled pid, not the session.
    private static let pidRecycleSlack: TimeInterval = 120
    // A subagent transcript untouched for this long is no longer running.
    private static let agentActivityWindow: TimeInterval = 90
    private static let maxRunningAgents = 8
    // Transcript tail windows. Runtime facts (model/context/skills) sit in
    // the last few hundred KB; the pending-prompt walk needs 2 MiB because
    // single tool_result lines reach 1.3 MB and noise runs exceed 200 KB.
    private static let runtimeTailBytes: UInt64 = 262_144
    private static let runtimeLineCap = 150
    private static let promptTailBytes: UInt64 = 2_097_152
    private static let promptLineCap = 250

    // Guards all mutable state below — refresh() and the 2s poll can run
    // loadActiveSessions concurrently.
    private let lock = NSLock()
    // Tracks waiting -> not-waiting transitions so a clear marker can be
    // appended to the events file: a manually denied permission dialog fires
    // NO hook, and without the marker its captured PermissionRequest would
    // linger as a phantom pending dialog.
    private var previousStatuses: [String: SessionStatus] = [:]
    // Transcript-tail parses reused until the file's mtime changes, so the
    // 2s poll doesn't re-decode 256 KB per session while nothing happens.
    private var runtimeCache: [String: (mtime: Date, model: String?, contextTokens: Double?, skills: [String])] = [:]
    // ~/.claude/settings.json parsed once per mtime for the same reason.
    private var userSettingsCache: (mtime: Date, effort: String?, model: String)?

    func loadActiveSessions() -> [SessionInfo] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: ClaudePaths.sessionsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        // Global defaults for per-session runtime facts: effort from user
        // settings when no hook event reported one; the [1m] model variant
        // widens the context window to 1M tokens.
        let (defaultEffort, settingsModel) = userSettingsDefaults()

        var bySessionId: [String: SessionInfo] = [:]
        var liveTranscriptPaths: Set<String> = []
        for file in files where file.pathExtension.lowercased() == "json" {
            guard
                let data = try? Data(contentsOf: file),
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                let pid = (obj["pid"] as? NSNumber)?.intValue,
                let sessionId = obj["sessionId"] as? String,
                let cwd = obj["cwd"] as? String,
                let updatedMs = (obj["updatedAt"] as? NSNumber)?.doubleValue
            else { continue }

            // Active = process still alive; signal 0 probes without sending.
            guard kill(pid_t(pid), 0) == 0 else { continue }
            // A crashed session leaves its registry file behind, and the pid
            // can be recycled by an unrelated process days later — which
            // would resurrect the entry (worst case as a permanent phantom
            // "waiting" session). A live pid that started noticeably after
            // the session did is such an impostor.
            if let startedMs = (obj["startedAt"] as? NSNumber)?.doubleValue,
               let procStart = Self.processStartTime(pid: pid),
               procStart.timeIntervalSince1970 > startedMs / 1000 + Self.pidRecycleSlack {
                continue
            }

            let status = (obj["status"] as? String) ?? "unknown"
            let state = SessionStatus(raw: status)
            let kind = obj["kind"] as? String
            let updatedAt = Date(timeIntervalSince1970: updatedMs / 1000)
            let transcript = transcriptURL(cwd: cwd, sessionId: sessionId)
            let transcriptMtime = mtime(of: transcript)
            liveTranscriptPaths.insert(transcript.path)
            // The statusline payload carries Claude Code's own context math
            // (matches /context); transcript inference is the fallback for
            // sessions without a fresh status capture.
            let reported = HookCapture.statusInfo(sessionId: sessionId, cwd: cwd)
            // Transcript is always walked (skills only live there); the
            // statusline payload overrides model/context when fresh.
            let transcriptRuntime = runtimeInfo(transcript: transcript, mtime: transcriptMtime)
            let runtime = reported?.contextPercent != nil
                ? (model: reported?.model, contextTokens: reported?.contextTokens)
                : (model: transcriptRuntime.model, contextTokens: transcriptRuntime.contextTokens)
            let statusUpdatedAt = (obj["statusUpdatedAt"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            noteStatusTransition(sessionId: sessionId, state: state)
            let info = SessionInfo(
                id: sessionId,
                name: (obj["name"] as? String) ?? sessionId,
                cwd: cwd,
                status: status,
                pid: pid,
                version: obj["version"] as? String,
                updatedAt: updatedAt,
                statusUpdatedAt: statusUpdatedAt,
                transcriptActivityAt: transcriptMtime,
                pendingPrompt: state == .waiting
                    ? pendingPrompt(sessionId: sessionId, transcript: transcript,
                                    statusChangedAt: statusUpdatedAt ?? updatedAt, cwd: cwd)
                    : nil,
                activeUse: ActiveUse(
                    skills: transcriptRuntime.skills,
                    agents: runningAgents(sessionDir: transcript.deletingPathExtension())
                ),
                model: runtime.model,
                contextTokens: runtime.contextTokens,
                contextLimit: reported?.contextPercent != nil
                    ? reported?.contextLimit
                    : Self.contextLimit(
                        model: runtime.model,
                        contextTokens: runtime.contextTokens,
                        settingsModel: settingsModel
                    ),
                effortLevel: reported?.effortLevel
                    ?? HookCapture.latestEffort(sessionId: sessionId)
                    ?? defaultEffort,
                reportedContextPercent: reported?.contextPercent,
                contextBreakdown: reported?.breakdown
            )
            // Claude Code also registers background processes under kind "bg":
            // pre-warmed spares from its process pool and headless resumes. A
            // spare inherits a finished session's registry file and keeps its
            // pid alive indefinitely, so the liveness probe alone shows ghost
            // sessions forever (observed live: three "claude bg-spare"
            // processes wearing old sessions' names). Background entries earn
            // a row only while they're demonstrably working.
            if kind == "bg", !info.isActivelyWorking {
                continue
            }
            if let existing = bySessionId[sessionId], existing.updatedAt >= info.updatedAt {
                continue
            }
            bySessionId[sessionId] = info
        }
        // Drop cache entries for sessions that vanished, so the cache can't
        // grow with process lifetime.
        lock.lock()
        runtimeCache = runtimeCache.filter { liveTranscriptPaths.contains($0.key) }
        lock.unlock()
        return bySessionId.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    // ~/.claude/settings.json re-parsed only when its mtime changes — the
    // 2s poll would otherwise decode it tens of thousands of times a day.
    private func userSettingsDefaults() -> (effort: String?, model: String) {
        let settingsMtime = mtime(of: ClaudePaths.userSettings) ?? .distantPast
        lock.lock()
        let cached = userSettingsCache
        lock.unlock()
        if let cached, cached.mtime == settingsMtime {
            return (cached.effort, cached.model)
        }
        let userSettings = (try? Data(contentsOf: ClaudePaths.userSettings))
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        let value = (effort: userSettings["effortLevel"] as? String,
                     model: (userSettings["model"] as? String) ?? "")
        lock.lock()
        userSettingsCache = (settingsMtime, value.effort, value.model)
        lock.unlock()
        return value
    }

    private func noteStatusTransition(sessionId: String, state: SessionStatus) {
        lock.lock()
        let previous = previousStatuses[sessionId]
        previousStatuses[sessionId] = state
        lock.unlock()
        if previous == .waiting, state != .waiting {
            HookCapture.appendClearMarker(sessionId: sessionId)
        }
    }

    static func processStartTime(pid: Int) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    // Claude Code stores the transcript at projects/<munged-cwd>/<sessionId>.jsonl,
    // munging the cwd per UTF-16 CODE UNIT (JS replace(/[^a-zA-Z0-9]/g,"-")
    // without the u flag): an emoji becomes TWO dashes (surrogate pair).
    // Mapping over Swift Characters would produce one dash and miss the
    // directory — verified against real Claude Code output.
    func transcriptURL(cwd: String, sessionId: String) -> URL {
        let munged = String(cwd.utf16.map { unit -> Character in
            let isAlnum = (0x30...0x39).contains(unit)
                || (0x41...0x5A).contains(unit)
                || (0x61...0x7A).contains(unit)
            guard isAlnum, let scalar = UnicodeScalar(unit) else { return "-" }
            return Character(scalar)
        })
        return ClaudePaths.projectsDir
            .appendingPathComponent(munged)
            .appendingPathComponent(sessionId)
            .appendingPathExtension("jsonl")
    }

    private func mtime(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // The settings "model" is an ALIAS ("opus[1m]", "sonnet"), never the
    // resolved id the transcript records ("claude-fable-5") — and a session
    // can override the model anyway. Observed context beyond the standard
    // window is definitive proof of a 1M window; the alias family match is
    // only a hint below that.
    static func contextLimit(model: String?, contextTokens: Double?, settingsModel: String) -> Double? {
        guard model != nil else { return nil }
        if let contextTokens, contextTokens > 190_000 { return 1_000_000 }
        let alias = settingsModel.lowercased()
        if alias.contains("[1m]") {
            let families = ["fable", "mythos", "opus", "sonnet", "haiku"]
            let sessionFamily = families.first { model!.lowercased().contains($0) }
            if let sessionFamily, alias.contains(sessionFamily) {
                return 1_000_000
            }
        }
        return 200_000
    }

    // Model, live context size, and skills invoked this turn, all from the
    // transcript tail. Skills MUST come from here: the harness expands Skill
    // invocations client-side and they never reach the hook pipeline (no
    // PreToolUse, not even a PostToolUse marker — verified empirically).
    // Passing the transcript's mtime enables the cache; the parse is reused
    // until the file changes.
    func runtimeInfo(transcript: URL, mtime: Date? = nil)
        -> (model: String?, contextTokens: Double?, skills: [String]) {
        if let mtime {
            lock.lock()
            let cached = runtimeCache[transcript.path]
            lock.unlock()
            if let cached, cached.mtime == mtime {
                return (cached.model, cached.contextTokens, cached.skills)
            }
        }
        let value = parseRuntimeInfo(transcript: transcript)
        if let mtime {
            lock.lock()
            runtimeCache[transcript.path] = (mtime, value.model, value.contextTokens, value.skills)
            lock.unlock()
        }
        return value
    }

    private func parseRuntimeInfo(transcript: URL)
        -> (model: String?, contextTokens: Double?, skills: [String]) {
        var model: String?
        var contextTokens: Double?
        var skills: [String] = []
        var pastTurnStart = false
        var examined = 0
        for line in TailReader.tailLines(of: transcript, maxBytes: Self.runtimeTailBytes).reversed() {
            if examined >= Self.runtimeLineCap { break }
            examined += 1
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  (obj["isSidechain"] as? Bool) != true,
                  let type = obj["type"] as? String,
                  let message = obj["message"] as? [String: Any]
            else { continue }
            if type == "user", !pastTurnStart {
                // Skill invocations leave exactly one trace: an injected
                // user message "Base directory for this skill: …/<name>".
                // Injected messages (skill content, command tags, interrupt
                // notes) must NOT count as the turn boundary — only a real
                // typed prompt does.
                var isBoundary = false
                if let text = message["content"] as? String {
                    isBoundary = !text.hasPrefix("[Request interrupted")
                } else if let blocks = message["content"] as? [[String: Any]] {
                    for block in blocks where (block["type"] as? String) == "text" {
                        guard let text = block["text"] as? String else { continue }
                        if text.hasPrefix("Base directory for this skill: ") {
                            let firstLine = text.prefix(while: { $0 != "\n" })
                            if let name = firstLine.split(separator: "/").last.map(String.init),
                               !skills.contains(name) {
                                skills.insert(name, at: 0)
                            }
                        } else if !text.hasPrefix("<"), !text.hasPrefix("[Request interrupted") {
                            isBoundary = true
                        }
                    }
                }
                if isBoundary { pastTurnStart = true }
            } else if type == "assistant" {
                if !pastTurnStart, let blocks = message["content"] as? [[String: Any]] {
                    for block in blocks where (block["type"] as? String) == "tool_use"
                        && (block["name"] as? String) == ToolName.skill {
                        if let name = (block["input"] as? [String: Any])?["skill"] as? String,
                           !skills.contains(name) {
                            skills.insert(name, at: 0)
                        }
                    }
                }
                if model == nil, let usage = message["usage"] as? [String: Any] {
                    let input = (usage["input_tokens"] as? NSNumber)?.doubleValue ?? 0
                    let cacheRead = (usage["cache_read_input_tokens"] as? NSNumber)?.doubleValue ?? 0
                    let cacheWrite = (usage["cache_creation_input_tokens"] as? NSNumber)?.doubleValue ?? 0
                    model = message["model"] as? String
                    contextTokens = input + cacheRead + cacheWrite
                }
            }
            if pastTurnStart, model != nil { break }
        }
        return (model, contextTokens, skills)
    }

    // A running subagent appends its transcript continuously, so a fresh
    // agent-*.jsonl under <session-dir>/subagents/ marks a live agent; the
    // sibling .meta.json names its type. Covers Agent-tool spawns and
    // workflow agents alike — no hooks required.
    func runningAgents(sessionDir: URL) -> [ActiveAgent] {
        let subagentsDir = sessionDir.appendingPathComponent("subagents")
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: subagentsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let cutoff = Date().addingTimeInterval(-Self.agentActivityWindow)
        var agents: [ActiveAgent] = []
        for case let file as URL in enumerator {
            guard file.pathExtension == "jsonl",
                  file.lastPathComponent.hasPrefix("agent-"),
                  let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  modified > cutoff
            else { continue }
            let metaURL = file.deletingPathExtension().appendingPathExtension("meta.json")
            var type = "subagent"
            var detail = ""
            if let data = try? Data(contentsOf: metaURL),
               let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                type = (meta["agentType"] as? String) ?? type
                detail = (meta["description"] as? String) ?? ""
            }
            let agent = ActiveAgent(type: type, detail: detail)
            if !agents.contains(agent) {
                agents.append(agent)
            }
            if agents.count >= Self.maxRunningAgents { break }
        }
        return agents
    }

    // Primary source: hook-captured events (exact content, written the moment
    // the dialog appears). Fallback: the transcript tail — unreliable, since
    // Claude Code flushes a tool_use and its result together only after
    // resolution, so mid-prompt the transcript usually lacks the blocking
    // tool entirely; when the flush does land early we can still use it.
    func pendingPrompt(sessionId: String, transcript: URL, statusChangedAt: Date?,
                       cwd: String = "") -> PendingPrompt? {
        let freshness = statusChangedAt?.addingTimeInterval(-600)
        if let state = HookCapture.latestState(sessionId: sessionId, notBefore: freshness) {
            switch state {
            case .pending(let tool, let input, let promptId, let suggestions):
                var prompt = buildPrompt(name: tool, input: input, suggestions: suggestions, cwd: cwd)
                prompt.promptId = promptId
                return prompt
            case .pendingMessage(let message):
                return PendingPrompt(toolName: "", title: "Waiting for your decision", detail: message, options: [])
            case .resolved:
                // Hooks are authoritative: the prompt was answered and the
                // registry status just hasn't flipped yet. Don't consult the
                // transcript — it would resurrect the answered prompt.
                return nil
            }
        }
        return transcriptPendingPrompt(in: transcript)
    }

    func transcriptPendingPrompt(in url: URL) -> PendingPrompt? {
        var resolved: [String: Bool] = [:]
        var examined = 0
        for line in TailReader.tailLines(of: url, maxBytes: Self.promptTailBytes).reversed() {
            if examined >= Self.promptLineCap { break }
            examined += 1
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = obj["type"] as? String,
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { continue }
            if type == "user" {
                for block in content where (block["type"] as? String) == "tool_result" {
                    // Walking backwards, the first line seen for an id is the
                    // newest — keep its verdict over older duplicates.
                    if let id = block["tool_use_id"] as? String, resolved[id] == nil {
                        resolved[id] = hasNonEmptyContent(block)
                    }
                }
            } else if type == "assistant" {
                guard let toolUse = content.last(where: { ($0["type"] as? String) == "tool_use" }),
                      let name = toolUse["name"] as? String
                else { continue }
                if let id = toolUse["id"] as? String, resolved[id] == true {
                    return nil
                }
                // Only blocking tools are trustworthy here: an unresolved
                // Bash/Edit/... line is usually an in-flight sibling of a
                // parallel batch (results flush after all siblings), not a
                // permission prompt — rendering it produced stale content.
                // Permission dialogs are covered by the hook pipeline.
                guard name == ToolName.askUserQuestion || name == ToolName.exitPlanMode else { return nil }
                return buildPrompt(name: name, input: (toolUse["input"] as? [String: Any]) ?? [:])
            }
        }
        return nil
    }

    private func hasNonEmptyContent(_ toolResult: [String: Any]) -> Bool {
        if let text = toolResult["content"] as? String {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let blocks = toolResult["content"] as? [[String: Any]] {
            return blocks.contains { block in
                if let text = block["text"] as? String {
                    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                return (block["type"] as? String) != "text"
            }
        }
        return false
    }

    func buildPrompt(name: String, input: [String: Any],
                     suggestions: [[String: Any]] = [], cwd: String = "") -> PendingPrompt {
        // Generous limits — the decision pane scrolls; clipping is only a
        // guard against pathological inputs, not a layout tool.
        func clip(_ s: String, _ n: Int = 700) -> String {
            s.count > n ? String(s.prefix(n)) + "…" : s
        }
        // Permission dialogs share one shape: the tool-specific content, the
        // terminal's consent question, and the terminal's real options —
        // wrapped as a single synthetic question so the answer wizard (option
        // rows, deny feedback, freeze-after-send) drives them unchanged.
        func permission(title: String, detail: String, question: String) -> PendingPrompt {
            let choices = Self.permissionChoices(toolName: name, suggestions: suggestions, cwd: cwd)
            let labels = choices.map(\.label)
            let fullQuestion = detail.isEmpty ? question : detail + "\n\n" + question
            return PendingPrompt(
                toolName: name,
                title: title,
                detail: detail,
                options: labels,
                answerable: true,
                allQuestions: [PromptQuestion(
                    question: fullQuestion, header: title, options: labels, isMultiSelect: false
                )],
                permissionChoices: choices,
                inputSignature: Self.inputSignature(of: input)
            )
        }
        switch name {
        case ToolName.askUserQuestion:
            guard let questions = input["questions"] as? [[String: Any]], let first = questions.first else {
                return PendingPrompt(toolName: name, title: "Question", detail: "", options: [])
            }
            let allQuestions = questions.map { raw in
                PromptQuestion(
                    question: clip((raw["question"] as? String) ?? ""),
                    header: (raw["header"] as? String) ?? "Question",
                    options: ((raw["options"] as? [[String: Any]]) ?? []).compactMap { $0["label"] as? String },
                    isMultiSelect: (raw["multiSelect"] as? Bool) ?? false
                )
            }
            let options = ((first["options"] as? [[String: Any]]) ?? []).compactMap { $0["label"] as? String }
            return PendingPrompt(
                toolName: name,
                title: (first["header"] as? String) ?? "Question",
                detail: clip((first["question"] as? String) ?? ""),
                options: options,
                isMultiSelect: (first["multiSelect"] as? Bool) ?? false,
                extraQuestionCount: max(0, questions.count - 1),
                // The stepper collects every question's answer (including
                // free text), so all AskUserQuestion prompts are answerable.
                answerable: !questions.isEmpty,
                allQuestions: allQuestions
            )
        case ToolName.exitPlanMode:
            return PendingPrompt(
                toolName: name,
                title: "Plan approval",
                detail: clip((input["plan"] as? String) ?? "Claude wants to start implementing its plan."),
                options: ["Approve", "Keep planning"]
            )
        case "Bash":
            let detail = (input["description"] as? String).flatMap { d in
                (input["command"] as? String).map { "\(d)\n$ \($0)" } ?? d
            } ?? (input["command"] as? String) ?? ""
            return permission(title: "Permission — run command", detail: clip(detail),
                              question: "Do you want to proceed?")
        case "Write", "Edit", "NotebookEdit":
            return permission(
                title: "Permission — \(name.lowercased()) file",
                detail: (input["file_path"] as? String) ?? "",
                question: "Do you want to proceed?"
            )
        case "WebFetch", "WebSearch":
            let target = (input["url"] as? String) ?? (input["query"] as? String) ?? ""
            return permission(title: "Permission — \(name)", detail: clip(target),
                              question: name == "WebFetch"
                                  ? "Do you want to allow Claude to fetch this content?"
                                  : "Do you want to proceed?")
        default:
            let compact = (try? JSONSerialization.data(withJSONObject: input))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return permission(title: "Permission — \(name)", detail: clip(compact, 300),
                              question: "Do you want to proceed?")
        }
    }

    // MARK: - Permission options

    // The island mirrors the terminal dialog's real rows: "Yes" and the deny
    // row always exist; the middle "don't ask again" row appears when Claude
    // Code sent permission suggestions, worded the way the terminal words it
    // (wordings verified against the Claude Code 2.1.217 dialog builders).
    static let permissionDenyLabel = "No, and tell Claude what to do differently"

    static func permissionChoices(toolName: String, suggestions: [[String: Any]],
                                  cwd: String) -> [PermissionChoice] {
        var choices = [PermissionChoice(label: "Yes", decision: .allow)]
        if let always = alwaysAllowLabel(toolName: toolName, suggestions: suggestions, cwd: cwd) {
            choices.append(PermissionChoice(label: always, decision: .allowAlways))
        }
        choices.append(PermissionChoice(label: permissionDenyLabel, decision: .deny))
        return choices
    }

    private struct SuggestedRule {
        let tool: String
        let content: String?
    }

    static func alwaysAllowLabel(toolName: String, suggestions: [[String: Any]],
                                 cwd: String) -> String? {
        var rules: [SuggestedRule] = []
        var directories: [String] = []
        var modes: [String] = []
        for suggestion in suggestions {
            switch suggestion["type"] as? String {
            case "addRules", "replaceRules":
                for rule in (suggestion["rules"] as? [[String: Any]]) ?? [] {
                    guard let tool = rule["toolName"] as? String else { continue }
                    rules.append(SuggestedRule(tool: tool, content: rule["ruleContent"] as? String))
                }
            case "addDirectories":
                directories.append(contentsOf: (suggestion["directories"] as? [String]) ?? [])
            case "setMode":
                if let mode = suggestion["mode"] as? String { modes.append(mode) }
            default:
                break
            }
        }

        // File-edit dialogs suggest a session-wide mode instead of a rule.
        if rules.isEmpty, directories.isEmpty {
            guard let mode = modes.first else { return nil }
            return mode == "acceptEdits"
                ? "Yes, allow all edits during this session"
                : "Yes, and switch to \(mode) mode"
        }

        let location = displayPath(cwd)
        if rules.count == 1, directories.isEmpty {
            let rule = rules[0]
            guard let content = rule.content else {
                // Whole-tool rule (e.g. WebSearch without ruleContent).
                return "Yes, and don't ask again for \(rule.tool)"
            }
            if content.hasPrefix("domain:") {
                return "Yes, and don't ask again for \(content.dropFirst("domain:".count))"
            }
            if content.hasSuffix(":*") || content.hasSuffix(" *") {
                return "Yes, and don't ask again for \(content.dropLast(2)) commands in \(location)"
            }
            if rule.tool == "Read" {
                return "Yes, allow reading from \(readPathDisplay(content)) from this project"
            }
            if rule.tool == "Bash" {
                // Exact command rule.
                return "Yes, and don't ask again for \(content)"
            }
            return "Yes, and don't ask again for \(rule.tool)(\(content))"
        }
        if rules.isEmpty {
            return "Yes, and always allow access to \(nameList(directories.map(displayPath))) from this project"
        }
        if directories.isEmpty, rules.allSatisfy({ $0.tool == "Read" }) {
            let paths = rules.compactMap { $0.content.map(readPathDisplay) }
            if paths.count == rules.count {
                return "Yes, allow reading from \(nameList(paths)) from this project"
            }
        }
        if directories.isEmpty, rules.allSatisfy({ $0.tool == toolName }) {
            let prefixes = rules.compactMap { rule in
                rule.content.map { content in
                    content.hasSuffix(":*") || content.hasSuffix(" *")
                        ? String(content.dropLast(2)) : content
                }
            }
            if prefixes.count == rules.count {
                return "Yes, and don't ask again for \(nameList(prefixes)) commands in \(location)"
            }
        }
        return "Yes, and add \(rules.count + directories.count) suggested permission rules"
    }

    // "a" / "a, b" / "a, b and N more" — the terminal's list formatter.
    private static func nameList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]), \(items[1])"
        default: return "\(items[0]), \(items[1]) and \(items.count - 2) more"
        }
    }

    // Read-rule contents cover subtrees ("src/**") and may be ./-relative.
    private static func readPathDisplay(_ content: String) -> String {
        var path = content
        if path.hasSuffix("/**") { path = String(path.dropLast(3)) }
        if path.hasPrefix("./") { path = String(path.dropFirst(2)) }
        return displayPath(path)
    }

    private static func displayPath(_ path: String) -> String {
        let home = ClaudePaths.home.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    // String-valued tool_input keys → value prefixes (sorted keys, capped),
    // written into the answer file so the hook can confirm a click targets
    // this exact dialog even among same-turn siblings of the same tool.
    static func inputSignature(of input: [String: Any]) -> [String: String] {
        var signature: [String: String] = [:]
        for key in input.keys.sorted() {
            guard let value = input[key] as? String, !value.isEmpty else { continue }
            signature[key] = String(value.prefix(160))
            if signature.count >= 4 { break }
        }
        return signature
    }
}
