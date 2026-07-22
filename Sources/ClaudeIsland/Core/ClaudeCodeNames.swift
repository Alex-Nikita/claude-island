import Foundation

// Names from Claude Code's hook protocol, shared by the capture installer,
// the event reader, and the prompt builders so they can't drift apart.
// The embedded shell/python scripts necessarily repeat these as literals —
// when editing either side, keep them in sync.

/// Tools whose names cross file boundaries (dialog gating, hook matchers).
enum ToolName {
    static let askUserQuestion = "AskUserQuestion"
    static let exitPlanMode = "ExitPlanMode"
    static let skill = "Skill"
}

/// hook_event_name values the island writes and replays.
enum HookEventName {
    static let preToolUse = "PreToolUse"
    static let permissionRequest = "PermissionRequest"
    static let notification = "Notification"
    static let postToolUse = "PostToolUse"
    static let postToolUseFailure = "PostToolUseFailure"
    static let userPromptSubmit = "UserPromptSubmit"
    static let stop = "Stop"
    static let sessionEnd = "SessionEnd"
    /// Synthesized by the island itself (not Claude Code) when a session
    /// leaves "waiting" without any hook having fired.
    static let islandStatusClear = "IslandStatusClear"
}
