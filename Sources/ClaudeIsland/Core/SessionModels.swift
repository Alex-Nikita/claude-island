import Foundation

// Claude Code's session registry writes free-form status strings; parse
// them once here so their semantics live in one place instead of scattered
// lowercased comparisons. Unknown strings survive as .other so new states
// degrade gracefully.
enum SessionStatus: Equatable {
    case busy
    case waiting
    case idle
    case other(String)

    init(raw: String) {
        switch raw.lowercased() {
        case "busy", "working", "running": self = .busy
        case "waiting": self = .waiting
        case "idle": self = .idle
        default: self = .other(raw.lowercased())
        }
    }
}

// One question of an AskUserQuestion prompt (they carry 1-4).
struct PromptQuestion: Equatable {
    let question: String
    let header: String
    let options: [String]
    let isMultiSelect: Bool
}

// What clicking a permission-prompt option makes the answer hook emit:
// plain allow, allow + persist Claude Code's suggested rules ("don't ask
// again"), or deny.
enum PermissionDecision: String, Equatable {
    case allow
    case allowAlways = "allow_always"
    case deny
}

struct PermissionChoice: Equatable {
    let label: String
    let decision: PermissionDecision
}

// Content of the prompt a waiting session is blocked on, captured by the
// hook pipeline (or the transcript-tail fallback).
struct PendingPrompt: Equatable {
    let toolName: String
    let title: String
    let detail: String
    let options: [String]
    var isMultiSelect: Bool = false
    var extraQuestionCount: Int = 0
    // True when the island can answer this prompt via the answer hook.
    var answerable: Bool = false
    // Every question, for the stepper flow; title/detail/options mirror the
    // first one for the display-only fallback path. Permission prompts are
    // modeled as one synthetic question so the same wizard machinery
    // (option rows, free text, freeze-after-send) drives them.
    var allQuestions: [PromptQuestion] = []
    // Claude Code's prompt_id — a per-TURN nonce (parallel dialogs in one
    // turn share it; verified live). Binds an answer file to the current
    // turn so a stale or planted file can't answer a future dialog; the
    // per-dialog binding comes from question prefixes (AskUserQuestion) or
    // toolName + inputSignature (permission prompts).
    var promptId: String? = nil
    // Non-empty marks a permission dialog: maps each option row to the
    // decision the answer hook should emit on click.
    var permissionChoices: [PermissionChoice] = []
    // String-valued tool_input keys → value prefixes; the answer hook
    // verifies these so a click can never answer a same-turn sibling
    // dialog of the same tool.
    var inputSignature: [String: String] = [:]

    var isPermission: Bool { !permissionChoices.isEmpty }
}

// What a session is exercising right now: skills invoked in the current
// turn (from hook capture) and subagents whose transcripts are being
// actively appended (works for Agent-tool spawns and workflow agents).
struct ActiveAgent: Equatable, Hashable {
    let type: String
    let detail: String
}

struct ActiveUse: Equatable {
    var skills: [String] = []
    var agents: [ActiveAgent] = []
}

// API-side composition of a session's context window (from the statusline
// payload's current_usage, or the transcript's last usage block).
struct ContextBreakdown: Equatable {
    var windowSize: Double
    var cacheRead: Double
    var cacheWrite: Double
    var input: Double
    var usedPercent: Double

    var usedTokens: Double { cacheRead + cacheWrite + input }
    var freeTokens: Double { max(0, windowSize - usedTokens) }
}

struct SessionInfo: Identifiable, Equatable {
    // A busy claim older than this is stale even without transcript
    // evidence — the registry's idle write can lag minutes under App Nap.
    static let registryFreshnessWindow: TimeInterval = 10 * 60
    // While claiming busy, a genuinely working session appends its
    // transcript at least this often.
    static let transcriptFreshnessWindow: TimeInterval = 150

    let id: String
    let name: String
    let cwd: String
    let status: String
    let pid: Int
    let version: String?
    let updatedAt: Date
    let statusUpdatedAt: Date?
    let transcriptActivityAt: Date?
    let pendingPrompt: PendingPrompt?
    var activeUse: ActiveUse = ActiveUse()
    // Runtime facts from the transcript tail / hook events: what model the
    // session last used, how full its context window is, and effort level.
    var model: String?
    var contextTokens: Double?
    var contextLimit: Double?
    var effortLevel: String?
    // Claude Code's own used_percentage from the statusline payload — the
    // authoritative number when present (matches /context).
    var reportedContextPercent: Double?
    var contextBreakdown: ContextBreakdown?

    /// The registry's raw status string, parsed.
    var state: SessionStatus { SessionStatus(raw: status) }

    var contextPercent: Int? {
        if let reportedContextPercent {
            return Int(min(100, max(0, reportedContextPercent)).rounded())
        }
        guard let contextTokens, let contextLimit, contextLimit > 0 else { return nil }
        return Int(min(100, max(0, contextTokens / contextLimit * 100)).rounded())
    }

    var modelShortName: String? {
        guard let model else { return nil }
        let lower = model.lowercased()
        if lower.contains("fable") { return "Fable" }
        if lower.contains("mythos") { return "Mythos" }
        if lower.contains("opus") { return "Opus" }
        if lower.contains("sonnet") { return "Sonnet" }
        if lower.contains("haiku") { return "Haiku" }
        return model.split(separator: "-").dropFirst().first.map(String.init) ?? model
    }

    var claimsBusy: Bool { state == .busy }

    // Claude Code sets status "waiting" while blocked on the user — a
    // question, plan approval, or permission prompt. No freshness guard: the
    // registry's updatedAt freezes the moment the session blocks, and the
    // prompt stays open however long the user is away. Dead sessions are
    // already excluded by the pid liveness probe.
    var needsAttention: Bool { state == .waiting }

    // The registry status can lag reality: the idle write may be delayed for
    // minutes when the terminal is backgrounded (App Nap). The transcript
    // file, however, is appended continuously while a session really works —
    // so "actively working" requires busy status AND a fresh transcript.
    var isActivelyWorking: Bool {
        guard claimsBusy else { return false }
        guard Date().timeIntervalSince(updatedAt) < Self.registryFreshnessWindow else { return false }
        guard let transcriptActivityAt else { return true }
        return Date().timeIntervalSince(transcriptActivityAt) < Self.transcriptFreshnessWindow
    }

    var displayStatus: String {
        if needsAttention { return "waiting for you" }
        return claimsBusy && !isActivelyWorking ? "\(status) (stale)" : status
    }
}
