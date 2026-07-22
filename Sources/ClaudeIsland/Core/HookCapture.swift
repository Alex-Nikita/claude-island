import Foundation

// Claude Code never flushes a pending tool_use to the transcript while its
// prompt is on screen (verified across 13k tool calls: use+result always land
// together after resolution), so the transcript alone can't show a question
// in time. Hooks can: PreToolUse fires with the full verbatim input before
// the dialog renders, PermissionRequest at dialog time, PostToolUse on
// resolution. A tiny shell script appends each event to a per-session JSONL
// file under ~/.claude/island/events/, and the app reads the tail.
//
// Full payloads are captured only for dialog-time events. Resolution events
// (PostToolUse etc.) fire for every tool and can carry megabyte responses,
// so they're written as tiny synthesized "marker" records instead — a huge
// line at the tail would push real events out of the read window.
enum HookCapture {
    static var islandDir: URL { ClaudePaths.claudeDir.appendingPathComponent("island") }
    static var eventsDir: URL { islandDir.appendingPathComponent("events") }
    static var scriptURL: URL { islandDir.appendingPathComponent("capture.sh") }
    static var settingsBackupURL: URL { islandDir.appendingPathComponent("settings-backup.json") }

    // Identify our entries inside the user's hooks config.
    private static let commandMarker = ".claude/island/capture.sh"
    private static let baseCommand = "\"$HOME/.claude/island/capture.sh\""
    private static let answerMarker = ".claude/island/answer.sh"
    private static let answerCommand = "\"$HOME/.claude/island/answer.sh\""

    private static let hookSpecs: [(event: String, matcher: String?, args: String)] = [
        // Skill is captured for the actively-in-use display, not as a dialog
        // — the pending reader only treats AskUserQuestion/ExitPlanMode
        // PreToolUse events as prompts.
        (HookEventName.preToolUse,
         [ToolName.askUserQuestion, ToolName.exitPlanMode, ToolName.skill].joined(separator: "|"),
         ""),
        (HookEventName.permissionRequest, nil, ""),
        (HookEventName.notification, nil, ""),
        (HookEventName.postToolUse, nil, " marker \(HookEventName.postToolUse)"),
        (HookEventName.postToolUseFailure, nil, " marker \(HookEventName.postToolUseFailure)"),
        (HookEventName.userPromptSubmit, nil, " marker \(HookEventName.userPromptSubmit)"),
        (HookEventName.stop, nil, " marker \(HookEventName.stop)"),
        (HookEventName.sessionEnd, nil, " marker \(HookEventName.sessionEnd)"),
    ]

    // Tail windows for the event readers: event files are small, and the
    // effort scan only needs the newest few records.
    private static let eventsTailBytes: UInt64 = 262_144
    private static let eventsLineCap = 300
    private static let effortTailBytes: UInt64 = 65_536
    // A statusline payload older than this says nothing about the session.
    static let defaultStatusMaxAge: TimeInterval = 900
    // Mirrors capture.sh's mkdir spinlock (100 spins × 10ms) — both sides
    // must agree or an app-side append can interleave with a hook write.
    private static let lockSpinLimit = 100
    private static let lockSpinDelay: useconds_t = 10_000

    // ${IN#*"key"} strips through the FIRST occurrence, so an embedded
    // "session_id" inside tool_input (e.g. in a Bash command) can't hijack
    // the filename. The mkdir spinlock serializes concurrent hook processes:
    // sh's printf flushes >1KB payloads in multiple write(2) calls, and
    // unserialized parallel appends interleave and corrupt both records.
    // Must exit 0 with empty stdout: hooks are awaited, and stdout on
    // success is parsed for decisions.
    private static let script = """
    #!/bin/sh
    # Installed by Claude Island (Settings > Precise prompt capture).
    # Usage: capture.sh              append full stdin JSON
    #        capture.sh marker <EV>  append a tiny resolution record
    DIR="$HOME/.claude/island/events"
    mkdir -p "$DIR" 2>/dev/null
    IN=$(cat)
    REST=${IN#*\\"session_id\\"}
    SID=$(printf '%s' "$REST" | /usr/bin/sed -n 's/^[^"]*"\\([0-9a-fA-F][0-9a-fA-F-]*\\)".*/\\1/p')
    [ -n "$SID" ] || SID=unknown
    if [ "$1" = "marker" ]; then
      TUID=""
      R2=${IN#*\\"tool_use_id\\"}
      [ "$R2" != "$IN" ] && TUID=$(printf '%s' "$R2" | /usr/bin/sed -n 's/^[^"]*"\\([A-Za-z0-9_-]*\\)".*/\\1/p')
      TN=""
      R3=${IN#*\\"tool_name\\"}
      [ "$R3" != "$IN" ] && TN=$(printf '%s' "$R3" | /usr/bin/sed -n 's/^[^"]*"\\([A-Za-z0-9_.:-]*\\)".*/\\1/p')
      OUT=$(printf '{"hook_event_name":"%s","session_id":"%s","tool_use_id":"%s","tool_name":"%s"}' "$2" "$SID" "$TUID" "$TN")
    else
      OUT=$IN
    fi
    LOCK="$DIR/.$SID.lock"
    n=0
    until /bin/mkdir "$LOCK" 2>/dev/null; do
      n=$((n+1))
      [ "$n" -gt 100 ] && break
      sleep 0.01 2>/dev/null || break
    done
    printf '%s\\n' "$OUT" >> "$DIR/$SID.jsonl" 2>/dev/null
    /bin/rmdir "$LOCK" 2>/dev/null
    exit 0

    """

    // Click-to-answer: a blocking PermissionRequest hook races the terminal
    // dialog (verified: Claude Code shows the dialog and runs these hooks
    // concurrently, first decision wins). It polls for the answer file the
    // island writes on chip click and submits the decision — question
    // answers via allow+updatedInput, permission clicks via allow (optionally
    // + the suggested rules) or deny.
    private static let answerScript = """
    #!/bin/sh
    # Installed by Claude Island (click-to-answer).
    command -v python3 >/dev/null 2>&1 || exit 0
    exec python3 "$HOME/.claude/island/answer.py"

    """

    private static let answerPython = #"""
    #!/usr/bin/env python3
    # Claude Island click-to-answer hook (PermissionRequest, all tools).
    # Claude Code races PermissionRequest hooks against the terminal dialog, so
    # this process blocks while the dialog is on screen. First to answer wins:
    # - island click  -> emit a decision (answers / allow / deny) -> dialog closes
    # - terminal answer -> a PostToolUse marker lands in the events file -> exit
    # Always exits 0 with either one line of decision JSON or no output.
    import json, os, re, sys, time

    POLL = 0.2
    # Env override exists for tests; production runs the 290s default,
    # under the hook entry's 300s timeout so we control the exit.
    DEADLINE = float(os.environ.get("ISLAND_ANSWER_DEADLINE", "290"))
    SID_RE = re.compile(r"^[A-Za-z0-9_-]{1,128}$")


    def emit(decision):
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": decision,
            }
        }))


    def question_decision(payload, ans):
        # AskUserQuestion: one island entry per question, matched by prefix.
        # Free-text values are legal (verified: non-label answers are accepted
        # verbatim); require EVERY question matched so a file for a different
        # prompt can never answer this one. Schema verified against Claude
        # Code 2.1.216+ (zod PermissionRequest decision) and live-tested:
        # questions echoed verbatim + answers record.
        tool_input = payload.get("tool_input") or {}
        entries = ans.get("answers") or []
        answers = {}
        for question in tool_input.get("questions") or []:
            text = question.get("question", "")
            match = next(
                (e for e in entries
                 if e.get("question_prefix") and text.startswith(e["question_prefix"])
                 and str(e.get("value", "")).strip()),
                None,
            )
            if match is None:
                return None
            answers[text] = str(match["value"])
        if not answers:
            return None
        updated = dict(tool_input)
        updated["answers"] = answers
        return {"behavior": "allow", "updatedInput": updated}


    def permission_decision(payload, ans):
        # Generic permission dialog: the island wrote which option was
        # clicked. Bind the click to THIS dialog: same tool, and every
        # captured input fingerprint (string-valued tool_input keys -> value
        # prefixes) must match — prompt_id alone is per-TURN, so parallel
        # same-turn dialogs need the input check to stay distinct.
        perm = ans.get("permission") or {}
        if perm.get("tool_name") != payload.get("tool_name"):
            return None
        tool_input = payload.get("tool_input") or {}
        sig = perm.get("input_sig") or {}
        for key, prefix in sig.items():
            value = tool_input.get(key)
            if not isinstance(value, str) or not value.startswith(str(prefix)):
                return None
        choice = perm.get("decision")
        if choice in ("allow", "allow_always"):
            # Echo the input verbatim — exactly what the terminal's own Yes
            # does. "Don't ask again" echoes Claude Code's suggested rules
            # verbatim; the CLI validates/sanitizes updatedPermissions itself.
            decision = {"behavior": "allow", "updatedInput": dict(tool_input)}
            suggestions = payload.get("permission_suggestions") or []
            if choice == "allow_always" and suggestions:
                decision["updatedPermissions"] = suggestions
            return decision
        if choice == "deny":
            decision = {"behavior": "deny"}
            message = str(perm.get("message") or "").strip()
            if message:
                decision["message"] = message
            return decision
        return None


    def main():
        try:
            payload = json.load(sys.stdin)
        except Exception:
            return
        if payload.get("hook_event_name") != "PermissionRequest":
            return
        tool_name = payload.get("tool_name") or ""
        # Plan approval has mode-changing semantics the island doesn't
        # replicate; it stays display-only, so don't race its dialog.
        if tool_name == "ExitPlanMode":
            return
        # Teammate/worker contexts await hooks BEFORE showing the dialog —
        # blocking there would delay it. Only race main-session dialogs.
        if payload.get("agent_id"):
            return
        is_question = tool_name == "AskUserQuestion"
        if is_question:
            questions = (payload.get("tool_input") or {}).get("questions") or []
            if not 1 <= len(questions) <= 4:
                return
        sid = payload.get("session_id", "")
        # Reject a session id that could escape the answers dir before we
        # build a path from it (defense-in-depth; ids are Claude Code UUIDs).
        if not sid or not SID_RE.match(sid):
            return
        # prompt_id is Claude Code's per-TURN nonce (all dialogs of one user
        # turn share it — verified live). Requiring a match binds the answer
        # file to the current turn so a stale/planted file can't answer a
        # future prompt; the per-dialog binding on top comes from question
        # prefixes (AskUserQuestion) or tool_name+input_sig (permissions).
        payload_prompt_id = payload.get("prompt_id")

        home = os.path.expanduser("~")
        answer_path = os.path.join(home, ".claude", "island", "answers", f"{sid}.json")
        events_path = os.path.join(home, ".claude", "island", "events", f"{sid}.jsonl")
        start = time.time()
        events_size_at_start = os.path.getsize(events_path) if os.path.exists(events_path) else 0

        while time.time() - start < DEADLINE:
            # Claude Code exited: we're orphaned (verified: losing hooks are
            # detached and never killed) — stop polling.
            if os.getppid() == 1:
                return
            try:
                st = os.stat(answer_path)
                if st.st_mtime >= start - 2:
                    with open(answer_path) as f:
                        ans = json.load(f)
                    file_prompt_id = ans.get("prompt_id")
                    # Fail closed: when Claude Code gives us a prompt_id, only
                    # accept a file that names the same one. A mismatch means
                    # the file targets a different turn (stale or planted) —
                    # leave it untouched so a fresh island write can claim it.
                    if payload_prompt_id and file_prompt_id != payload_prompt_id:
                        pass
                    else:
                        decision = (question_decision if is_question
                                    else permission_decision)(payload, ans)
                        # Consume only what this racer can submit: parallel
                        # dialogs each run their own hook instance, and a file
                        # for a same-turn sibling must stay on disk for the
                        # instance it belongs to.
                        if decision is not None:
                            os.unlink(answer_path)
                            emit(decision)
                            return
            except FileNotFoundError:
                pass
            except Exception:
                # Only discard the file on a parse/read error we can attribute
                # to THIS prompt — never blindly unlink another dialog's file.
                try:
                    with open(answer_path) as f:
                        stale = json.load(f)
                    if not payload_prompt_id or stale.get("prompt_id") in (None, payload_prompt_id):
                        os.unlink(answer_path)
                except Exception:
                    pass
            # Answered in the terminal? New events after our start mean
            # movement; stop racing. Tool markers only end OUR race when they
            # name our tool — a parallel sibling resolving must not kill the
            # racer of a dialog still on screen.
            try:
                size = os.path.getsize(events_path)
                if size > events_size_at_start:
                    with open(events_path, "rb") as f:
                        f.seek(events_size_at_start)
                        fresh = f.read().decode("utf-8", "replace")
                    for line in fresh.splitlines():
                        try:
                            ev = json.loads(line)
                        except Exception:
                            continue
                        name = ev.get("hook_event_name", "")
                        if name in ("Stop", "UserPromptSubmit",
                                    "IslandStatusClear", "SessionEnd"):
                            return
                        if name in ("PostToolUse", "PostToolUseFailure"):
                            marker_tool = ev.get("tool_name") or ""
                            if not marker_tool or marker_tool == tool_name:
                                return
                    events_size_at_start = size
            except OSError:
                pass
            time.sleep(POLL)


    if __name__ == "__main__":
        try:
            main()
        except Exception:
            pass
        sys.exit(0)

    """#

    // The statusline payload is the only place Claude Code exports its OWN
    // context accounting (context_window.used_percentage — the same math as
    // /context and auto-compact). The script saves the payload per session
    // and renders a simple useful line in return for taking the slot.
    static var statusDir: URL { islandDir.appendingPathComponent("status") }
    static var statusScriptURL: URL { islandDir.appendingPathComponent("statusline.sh") }
    private static let statusMarker = ".claude/island/statusline.sh"
    private static let statusCommand = "\"$HOME/.claude/island/statusline.sh\""

    private static let statusScript = """
    #!/bin/sh
    # Installed by Claude Island: saves Claude Code's status payload (incl.
    # its own context accounting) per session, and renders the status line.
    DIR="$HOME/.claude/island/status"
    mkdir -p "$DIR" 2>/dev/null
    IN=$(cat)
    REST=${IN#*\\"session_id\\"}
    SID=$(printf '%s' "$REST" | /usr/bin/sed -n 's/^[^"]*"\\([0-9a-fA-F][0-9a-fA-F-]*\\)".*/\\1/p')
    [ -n "$SID" ] || SID=unknown
    printf '%s' "$IN" > "$DIR/$SID.json.tmp" && mv "$DIR/$SID.json.tmp" "$DIR/$SID.json"
    MODEL=$(printf '%s' "$IN" | /usr/bin/sed -n 's/.*"display_name":"\\([^"]*\\)".*/\\1/p' | head -1)
    PCT=$(printf '%s' "$IN" | /usr/bin/sed -n 's/.*"used_percentage":\\([0-9.]*\\).*/\\1/p' | head -1)
    CWD=$(printf '%s' "$IN" | /usr/bin/sed -n 's/.*"current_dir":"\\([^"]*\\)".*/\\1/p' | head -1)
    LINE="${CWD##*/}"
    [ -n "$MODEL" ] && LINE="$LINE · $MODEL"
    [ -n "$PCT" ] && LINE="$LINE · ${PCT%%.*}% context"
    printf '%s\\n' "$LINE"
    exit 0

    """

    // Claude Code's own view of a session's context window, captured from
    // the statusline payload. Far more accurate than transcript inference.
    struct StatusInfo {
        var model: String?
        var effortLevel: String?
        var contextPercent: Double?
        var contextTokens: Double?
        var contextLimit: Double?
        var breakdown: ContextBreakdown?
    }

    static func statusInfo(sessionId: String, cwd: String? = nil,
                           maxAge: TimeInterval = defaultStatusMaxAge) -> StatusInfo? {
        var url = statusDir.appendingPathComponent(sessionId).appendingPathExtension("json")
        // Background-job sessions report a different session_id in the
        // statusline payload than the registry uses — fall back to the
        // freshest payload whose workspace matches the session's cwd.
        if !FileManager.default.fileExists(atPath: url.path), let cwd {
            let candidates = ((try? FileManager.default.contentsOfDirectory(
                at: statusDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []).filter { candidate in
                guard let data = try? Data(contentsOf: candidate),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let workspace = obj["workspace"] as? [String: Any]
                else { return false }
                return (workspace["current_dir"] as? String) == cwd
            }
            guard let freshest = candidates.max(by: {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
                    < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
            }) else { return nil }
            url = freshest
        }
        guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              Date().timeIntervalSince(mtime) < maxAge,
              let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        var info = StatusInfo()
        info.model = ((obj["model"] as? [String: Any])?["display_name"] as? String)
            ?? ((obj["model"] as? [String: Any])?["id"] as? String)
        info.effortLevel = (obj["effort"] as? [String: Any])?["level"] as? String
        if let window = obj["context_window"] as? [String: Any] {
            info.contextPercent = (window["used_percentage"] as? NSNumber)?.doubleValue
            info.contextLimit = (window["context_window_size"] as? NSNumber)?.doubleValue
            if let usage = window["current_usage"] as? [String: Any] {
                func value(_ key: String) -> Double {
                    (usage[key] as? NSNumber)?.doubleValue ?? 0
                }
                let cacheRead = value("cache_read_input_tokens")
                let cacheWrite = value("cache_creation_input_tokens")
                let input = value("input_tokens")
                info.contextTokens = cacheRead + cacheWrite + input
                if let size = info.contextLimit, size > 0 {
                    info.breakdown = ContextBreakdown(
                        windowSize: size,
                        cacheRead: cacheRead,
                        cacheWrite: cacheWrite,
                        input: input,
                        usedPercent: info.contextPercent ?? (info.contextTokens! / size * 100)
                    )
                }
            }
        }
        return info
    }

    enum PromptState {
        case pending(tool: String, input: [String: Any], promptId: String?,
                     suggestions: [[String: Any]])
        case pendingMessage(String)
        case resolved
    }

    struct SettingsError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // Session ids come from files Claude Code writes (trusted today), but they
    // flow into file-path construction. Restrict to a UUID-ish alphabet so a
    // value can never contain "/" or ".." and escape the island directory —
    // defense-in-depth if a future Claude Code change lets session metadata
    // carry attacker-influenced strings.
    static func isSafeSessionId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128
            && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    // MARK: - Install / remove

    static var isInstalled: Bool {
        guard let hooks = readSettingsLenient()["hooks"] as? [String: Any],
              let pre = hooks["PreToolUse"] as? [[String: Any]]
        else { return false }
        return pre.contains { containsCommand($0, commandMarker) }
    }

    /// Writes the embedded scripts to ~/.claude/island/. Touches only our own
    /// files — never settings.json — so it is safe to run on every launch.
    static func writeScripts() throws {
        let fm = FileManager.default
        // Owner-only: these dirs hold prompt content and typed answers.
        try fm.createDirectory(at: islandDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: islandDir.path)
        for dir in [eventsDir, answersDir, statusDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            // createDirectory won't relax an already-existing dir, so fix
            // perms on installs that predate this hardening.
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try answerScript.write(to: answerScriptURL, atomically: true, encoding: .utf8)
        try answerPython.write(to: answerPythonURL, atomically: true, encoding: .utf8)
        try statusScript.write(to: statusScriptURL, atomically: true, encoding: .utf8)
        for path in [scriptURL.path, answerScriptURL.path, statusScriptURL.path] {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
    }

    /// Hooks reference scripts on disk; the embedded copies evolve with the
    /// app. Re-sync at launch so an upgraded app never runs stale scripts.
    static func refreshScriptsIfInstalled() {
        guard isInstalled else { return }
        try? writeScripts()
    }

    static func install() throws {
        let fm = FileManager.default
        try writeScripts()

        var settings = try readSettingsStrict()
        if fm.fileExists(atPath: ClaudePaths.userSettings.path) {
            try? fm.removeItem(at: settingsBackupURL)
            try? fm.copyItem(at: ClaudePaths.userSettings, to: settingsBackupURL)
        }
        // Claim the statusline slot only when the user hasn't configured one
        // — never clobber a custom statusline.
        if settings["statusLine"] == nil {
            settings["statusLine"] = ["type": "command", "command": statusCommand]
        }
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        for spec in hookSpecs {
            var entries = (hooks[spec.event] as? [[String: Any]]) ?? []
            guard !entries.contains(where: { containsCommand($0, commandMarker) }) else { continue }
            var entry: [String: Any] = [
                "hooks": [["type": "command", "command": baseCommand + spec.args, "timeout": 5]]
            ]
            if let matcher = spec.matcher { entry["matcher"] = matcher }
            entries.append(entry)
            hooks[spec.event] = entries
        }
        // The blocking answerer races the dialog; its own deadline (290s)
        // sits under this timeout so it always exits on its own terms. No
        // matcher: it answers every tool's permission dialog (the script
        // itself skips ExitPlanMode and teammate contexts).
        var permissionEntries = (hooks["PermissionRequest"] as? [[String: Any]]) ?? []
        if !permissionEntries.contains(where: { containsCommand($0, answerMarker) }) {
            permissionEntries.append([
                "hooks": [["type": "command", "command": answerCommand, "timeout": 300]],
            ])
            hooks["PermissionRequest"] = permissionEntries
        }
        settings["hooks"] = hooks
        try writeSettings(settings)
    }

    static func uninstall() throws {
        var settings = try readSettingsStrict()
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for event in hooks.keys {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            entries.removeAll { containsCommand($0, ".claude/island/") }
            hooks[event] = entries.isEmpty ? nil : entries
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        // Remove the statusline only if it's ours.
        if let statusLine = settings["statusLine"] as? [String: Any],
           (statusLine["command"] as? String)?.contains(statusMarker) == true {
            settings["statusLine"] = nil
        }
        try writeSettings(settings)
        for url in [scriptURL, answerScriptURL, answerPythonURL, statusScriptURL] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func containsCommand(_ entry: [String: Any], _ marker: String) -> Bool {
        ((entry["hooks"] as? [[String: Any]]) ?? []).contains {
            ($0["command"] as? String)?.contains(marker) == true
        }
    }

    private static func readSettingsLenient() -> [String: Any] {
        guard let data = try? Data(contentsOf: ClaudePaths.userSettings),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        return obj
    }

    // A missing file is a legitimate empty config; an existing file that
    // fails to read or parse is NOT — merging into [:] and writing back
    // would silently destroy the user's entire settings.json.
    private static func readSettingsStrict() throws -> [String: Any] {
        let url = ClaudePaths.userSettings
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SettingsError(message: "~/.claude/settings.json isn't valid JSON — fix or remove it, then retry")
        }
        return obj
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: ClaudePaths.userSettings, options: .atomic)
    }

    // MARK: - Reading captured events

    private struct PendingDialog {
        let tool: String
        let input: [String: Any]
        let inputKey: Data?
        var toolUseId: String?
        // Only PermissionRequest carries prompt_id; PreToolUse for the same
        // dialog does not, so this is filled in whichever event provides it.
        var promptId: String?
        // permission_suggestions from the PermissionRequest payload — the
        // material for the dialog's "don't ask again" option.
        var suggestions: [[String: Any]] = []
    }

    // Replays the captured events (oldest to newest within the tail window)
    // into the set of dialogs still awaiting an answer. Dialogs display
    // FIFO in Claude Code, so the oldest unresolved one is on screen.
    // notBefore guards against stale files (hooks removed, capture broken):
    // events older than the waiting-status flip minus slack say nothing
    // about the CURRENT prompt.
    static func latestState(sessionId: String, notBefore: Date?) -> PromptState? {
        guard isSafeSessionId(sessionId) else { return nil }
        let url = eventsDir.appendingPathComponent(sessionId).appendingPathExtension("jsonl")
        if let notBefore,
           let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           mtime < notBefore {
            return nil
        }
        guard let data = TailReader.tail(of: url, maxBytes: eventsTailBytes) else { return nil }
        let lines = data.split(separator: UInt8(ascii: "\n")).suffix(eventsLineCap)
        var pendings: [PendingDialog] = []
        var lastNotification: String?
        var sawAnyEvent = false

        for line in lines {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let event = obj["hook_event_name"] as? String
            else { continue }
            sawAnyEvent = true
            switch event {
            case HookEventName.preToolUse, HookEventName.permissionRequest:
                guard let tool = obj["tool_name"] as? String else { continue }
                // PreToolUse fires for non-dialog tools too (Skill, captured
                // for the in-use display); only blocking tools are prompts.
                // PermissionRequest always is one — it fires per dialog.
                if event == HookEventName.preToolUse,
                   tool != ToolName.askUserQuestion, tool != ToolName.exitPlanMode {
                    continue
                }
                let input = (obj["tool_input"] as? [String: Any]) ?? [:]
                let key = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
                let toolUseId = obj["tool_use_id"] as? String
                let promptId = obj["prompt_id"] as? String
                let suggestions = (obj["permission_suggestions"] as? [[String: Any]]) ?? []
                // PreToolUse and PermissionRequest both fire for the same
                // dialog (AskUserQuestion/ExitPlanMode) — same tool + same
                // input is one dialog, not two.
                if let idx = pendings.firstIndex(where: { $0.tool == tool && $0.inputKey == key }) {
                    if pendings[idx].toolUseId == nil { pendings[idx].toolUseId = toolUseId }
                    if pendings[idx].promptId == nil { pendings[idx].promptId = promptId }
                    if pendings[idx].suggestions.isEmpty { pendings[idx].suggestions = suggestions }
                } else {
                    pendings.append(PendingDialog(tool: tool, input: input, inputKey: key,
                                                  toolUseId: toolUseId, promptId: promptId,
                                                  suggestions: suggestions))
                }
                lastNotification = nil
            case HookEventName.postToolUse, HookEventName.postToolUseFailure:
                // Marker record. Match by tool_use_id, else oldest same-name
                // dialog. A marker matching nothing is an auto-approved tool
                // that never showed a dialog — ignore it entirely.
                let toolUseId = (obj["tool_use_id"] as? String) ?? ""
                let tool = (obj["tool_name"] as? String) ?? ""
                if !toolUseId.isEmpty, let idx = pendings.firstIndex(where: { $0.toolUseId == toolUseId }) {
                    pendings.remove(at: idx)
                    lastNotification = nil
                } else if !tool.isEmpty, let idx = pendings.firstIndex(where: { $0.tool == tool }) {
                    pendings.remove(at: idx)
                    lastNotification = nil
                }
            case HookEventName.stop, HookEventName.userPromptSubmit,
                 HookEventName.sessionEnd, HookEventName.islandStatusClear:
                pendings.removeAll()
                lastNotification = nil
            case HookEventName.notification:
                // Dialogs that fire no input-carrying event (MCP elicitation,
                // sandbox requests) at least announce themselves here.
                lastNotification = (obj["message"] as? String) ?? "Claude needs your input."
            default:
                continue
            }
        }
        if let oldest = pendings.first {
            return .pending(tool: oldest.tool, input: oldest.input, promptId: oldest.promptId,
                            suggestions: oldest.suggestions)
        }
        if let lastNotification {
            return .pendingMessage(lastNotification)
        }
        return sawAnyEvent ? .resolved : nil
    }

    // MARK: - Click-to-answer

    static var answersDir: URL { islandDir.appendingPathComponent("answers") }
    static var answerScriptURL: URL { islandDir.appendingPathComponent("answer.sh") }
    static var answerPythonURL: URL { islandDir.appendingPathComponent("answer.py") }

    static var isClickToAnswerInstalled: Bool {
        guard FileManager.default.fileExists(atPath: answerScriptURL.path),
              let hooks = readSettingsLenient()["hooks"] as? [String: Any]
        else { return false }
        return hooks.values.contains { value in
            ((value as? [[String: Any]]) ?? []).contains { entry in
                ((entry["hooks"] as? [[String: Any]]) ?? []).contains {
                    ($0["command"] as? String)?.contains(".claude/island/answer.sh") == true
                }
            }
        }
    }

    // The island's collected answers (one value per question — a label,
    // comma-joined labels, or free text) drop here; the blocking answer hook
    // (racing the terminal dialog) polls for the file, matches each question
    // by prefix, and submits the whole set to Claude Code. promptId is Claude
    // Code's per-TURN nonce (parallel dialogs share it): the hook rejects any
    // file whose prompt_id doesn't match its own, so a stale/planted file
    // can't answer a future prompt; within a turn the question prefixes are
    // the per-dialog binding.
    static func writeAnswer(sessionId: String, answers: [(question: String, value: String)],
                            promptId: String? = nil) {
        var payload: [String: Any] = [
            "answers": answers.map {
                ["question_prefix": String($0.question.prefix(200)), "value": $0.value]
            },
        ]
        if let promptId { payload["prompt_id"] = promptId }
        writeAnswerFile(payload, sessionId: sessionId)
    }

    // A clicked permission option drops here. The hook validates tool
    // identity + the input fingerprint (+ the turn's prompt_id) and emits
    // the decision: allow (input echoed verbatim), allow + Claude Code's
    // own suggested rules ("don't ask again"), or deny with optional
    // "what to do differently" feedback.
    static func writePermissionAnswer(
        sessionId: String,
        toolName: String,
        inputSignature: [String: String],
        decision: PermissionDecision,
        message: String? = nil,
        promptId: String? = nil
    ) {
        var permission: [String: Any] = [
            "tool_name": toolName,
            "input_sig": inputSignature,
            "decision": decision.rawValue,
        ]
        if let message, !message.isEmpty { permission["message"] = message }
        var payload: [String: Any] = ["permission": permission]
        if let promptId { payload["prompt_id"] = promptId }
        writeAnswerFile(payload, sessionId: sessionId)
    }

    private static func writeAnswerFile(_ payload: [String: Any], sessionId: String) {
        guard isSafeSessionId(sessionId),
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        createIslandDir(answersDir)
        let url = answersDir.appendingPathComponent(sessionId).appendingPathExtension("json")
        try? data.write(to: url, options: .atomic)
    }

    // Creates an island subdirectory owner-only (0o700) so answers/events/
    // status — which can carry prompt content and typed answers — aren't
    // left group/world-readable. Fixes perms on an already-existing dir too.
    private static func createIslandDir(_ url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: islandDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: islandDir.path)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    }

    // Appended by the app itself when it observes a session leave "waiting":
    // a manually denied permission dialog fires no hook at all, so without
    // this the denied dialog's PermissionRequest would linger as the oldest
    // pending and shadow the next real dialog. Uses the same mkdir spinlock
    // as capture.sh so the append can't interleave with a hook write.
    static func appendClearMarker(sessionId: String) {
        guard isSafeSessionId(sessionId) else { return }
        // Only meaningful when capture is active; don't create files otherwise.
        guard FileManager.default.fileExists(atPath: scriptURL.path) else { return }
        let url = eventsDir.appendingPathComponent(sessionId).appendingPathExtension("jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let line = "{\"hook_event_name\":\"\(HookEventName.islandStatusClear)\",\"session_id\":\"\(sessionId)\"}\n"
        guard let data = line.data(using: .utf8) else { return }
        let lock = eventsDir.appendingPathComponent(".\(sessionId).lock")
        var spins = 0
        while (try? FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)) == nil {
            spins += 1
            if spins > Self.lockSpinLimit { break }
            usleep(Self.lockSpinDelay)
        }
        defer { try? FileManager.default.removeItem(at: lock) }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    // Latest effort level a hook payload reported for this session (hook
    // events carry effort:{level} on tool-context events). Nil when no
    // dialog-adjacent event captured one yet.
    static func latestEffort(sessionId: String) -> String? {
        let url = eventsDir.appendingPathComponent(sessionId).appendingPathExtension("jsonl")
        for line in TailReader.tailLines(of: url, maxBytes: effortTailBytes).reversed() {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let effort = obj["effort"] as? [String: Any],
                  let level = effort["level"] as? String
            else { continue }
            return level
        }
        return nil
    }

    // Capture files outlive their sessions; sweep events, status payloads,
    // and unconsumed answers occasionally. Status files matter most: the
    // cwd fallback in statusInfo scans that whole directory, so its cost
    // grows with every file left behind.
    static func pruneStaleFiles(olderThan interval: TimeInterval = 7 * 24 * 3600) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-interval)
        for dir in [eventsDir, statusDir, answersDir] {
            let files = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for file in files {
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let mtime, mtime < cutoff {
                    try? fm.removeItem(at: file)
                }
            }
        }
    }
}
