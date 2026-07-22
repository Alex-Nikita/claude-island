# Claude Island — Design & Contracts

A macOS menu bar / notch app showing **% of Claude usage left**, built with SwiftUI + AppKit,
SwiftPM executable target bundled into `Claude Island.app` (see `Makefile`).

Target: macOS 14+, Swift language mode 5. No third-party dependencies.

## Two display modes

1. **Pill mode** (default): an `NSStatusItem` in the menu bar rendering a rounded **orange pill**
   (Claude orange `#D97757`) with white bold text like `63%`. Clicking opens an `NSPopover`
   with usage details and settings.
2. **Notch mode** (advanced toggle, "Boring Notch"-style): a borderless panel over the camera
   notch. Collapsed: black shape blending with the notch, **Claude logo on the left wing, `63%`
   on the right wing**. Clicking the logo expands the island **downwards and outwards**:
   - Center: the **active session** with `<` `>` to cycle between running Claude Code sessions.
   - Left: vertical nav tabs **Skills / Hooks / Subagents**.
   - Right: the list of items for the selected tab, scoped to the selected session.

## File layout

All paths below `Sources/ClaudeIsland/`.

**Core** — pure logic, no UI imports, unit-tested:
- Models, split by domain: `SettingsModels.swift` (display/settings enums),
  `UsageModels.swift` (`UsageQuery`/`UsageSnapshot`/limits), `SessionModels.swift`
  (`SessionStatus`/`SessionInfo`/`PendingPrompt`), `CapabilityModels.swift`,
  `ClaudePaths.swift`
- `AppSettings.swift` — persisted settings; every key single-sourced in a `Key` enum
- `UsageEngine.swift`, `JSONLScanner.swift`, `OAuthUsageFetcher.swift` (an actor),
  `Pricing.swift` (owns the cache-weight ratios), `UsageSummary.swift` (every
  user-facing usage string derives here)
- `SessionMonitor.swift`, `CapabilityScanner.swift`, `HookCapture.swift`,
  `AnswerFlow.swift`
- Utilities: `Format.swift` (dollars/tokens formatting), `TailReader.swift`
  (JSONL tail windows), `ClaudeCodeNames.swift` (hook/tool name constants),
  `DebugFlags.swift` (CI_* switches)

**App** — `ClaudeIslandApp.swift` (@main + AppDelegate + mode switching),
`AppState.swift` (central @MainActor state, refresh loop), `ClaudeLogo.swift`,
`AttentionBorder.swift`, `BorderTrail.swift`

**Shared** — used by both display modes: `Theme.swift` (palette, `SemanticColors`,
`Thresholds`), `SettingsView.swift`

**PillMode** — `PillModeController.swift`, `PillView.swift`, `DropdownView.swift`

**NotchMode** — `NotchModeController.swift` (+ `NotchUIModel`, `CapabilityTab`),
`NotchShape.swift`, `CollapsedNotchView.swift`, `ExpandedIslandView.swift` (the
shell: shape/wing strip/routing), and one file per screen:
`CapabilityBrowserView.swift`, `DecisionPaneView.swift`, `CapabilityDetailView.swift`,
`ContextScreenView.swift`, `IslandSettingsPane.swift`, `SessionPickerOverlay.swift`,
plus `IslandComponents.swift` for shared building blocks.

## Usage sources (the settings "fine-tune")

`UsageSource` enum — three ways to compute % left:

1. `officialAPI` — GET `https://api.anthropic.com/api/oauth/usage` with headers
   `Authorization: Bearer <accessToken>` and `anthropic-beta: oauth-2025-04-20`.
   The access token lives in the macOS Keychain: generic password, service
   `"Claude Code-credentials"`. The keychain item's data is JSON:
   `{"claudeAiOauth":{"accessToken":"...","refreshToken":"...","expiresAt":<ms-epoch>,...}}`.
   If `expiresAt` is past → treat as failure (do NOT implement token refresh).
   Response shape (parse defensively as `[String: Any]`, keys may drift): expect objects like
   `"five_hour": {"utilization": <0-100 number>, "resets_at": "<ISO8601>"}` and
   `"seven_day": {...}` (possibly also `seven_day_opus` etc — ignore extras).
   If the JSON has no recognizable utilization for the requested window, throw.
   **On any failure the engine falls back to `tokenCounts`** and prefixes
   `sourceLabel` with `"Official API unavailable — "`.

2. `tokenCounts` ("cached usage responses that claude json stores") — parse the per-response
   `usage` blocks Claude Code appends to `~/.claude/projects/<munged-cwd>/<session>.jsonl`.
   Relevant JSONL entry fields:
   ```json
   {"type":"assistant","timestamp":"2026-07-10T17:32:55.214Z","requestId":"req_...",
    "message":{"id":"msg_...","model":"claude-fable-5",
      "usage":{"input_tokens":3883,"cache_creation_input_tokens":6735,
               "cache_read_input_tokens":18341,"output_tokens":116,
               "cache_creation":{"ephemeral_1h_input_tokens":6735,"ephemeral_5m_input_tokens":0}}}}
   ```
   Rules: only `type == "assistant"` entries with a `message.usage`; **dedupe by `message.id`**
   (fall back to `requestId` when id missing; entries can be duplicated across files);
   window-filter by `timestamp` (ISO8601 with fractional seconds); skip files whose mtime is
   older than the window start (appends bump mtime). Ignore `usage.iterations` (top-level
   fields already aggregate). "Tokens used" = input + output + cache_creation + cache_read.
   % left = `100 * (1 - used / tokenBudget)` clamped to 0...100.

3. `costEstimate` — same scanned totals, converted to dollars via the pricing table below,
   then multiplied by `costMultiplier` (enterprise-discount multiplier, default 1.0 — for
   orgs whose negotiated rates are cheaper than list price). % left vs `costBudget`.

**Windows** (`UsageWindow`): `.fiveHour` = rolling `[now-5h, now]`, `.weekly` = rolling
`[now-7d, now]`. These are approximations of Claude's real windows (label them "rolling");
the `officialAPI` source is exact.

## Pricing table (USD per 1M tokens) — `Pricing.swift`

| model id prefix | input | output |
|---|---|---|
| `claude-fable-5`, `claude-mythos` | 10 | 50 |
| `claude-opus-4-1`, `claude-opus-4-0`, `claude-opus-4-2`(0514 era) | 15 | 75 |
| `claude-opus-4` (4-5/4-6/4-7/4-8 and default opus) | 5 | 25 |
| `claude-sonnet-5` | 2 | 10 (intro until 2026-08-31, then 3/15 — check current date) |
| `claude-sonnet` (all others incl 4-x, 3-x) | 3 | 15 |
| `claude-haiku-4-5` | 1 | 5 |
| `claude-3-5-haiku` | 0.8 | 4 |
| `claude-3-haiku` | 0.25 | 1.25 |
| unknown fallback | 5 | 25 |

Cache pricing relative to that model's **input** price: 5-minute cache write ×1.25,
1-hour cache write ×2.0, cache read ×0.1. Use `cache_creation.ephemeral_1h_input_tokens` /
`ephemeral_5m_input_tokens` when present; else treat all `cache_creation_input_tokens` as 5m.
Match model → row by longest matching prefix (order matters: check `claude-opus-4-1` before `claude-opus-4`).

## Contracts to implement (exact signatures)

Foundation code calls these — implement them exactly:

```swift
// usage-core
struct TokenTotals { var input = 0.0, output = 0.0, cacheRead = 0.0, cacheWrite5m = 0.0, cacheWrite1h = 0.0 }
final class JSONLScanner {
    // totals per model id, deduped, for entries with timestamp >= since
    func collectUsage(since: Date) throws -> [String: TokenTotals]
}
enum Pricing {
    static func cost(model: String, totals: TokenTotals) -> Double  // USD
}
struct OfficialUsage {
    let fiveHourUtilization: Double?; let fiveHourResetsAt: Date?
    let sevenDayUtilization: Double?; let sevenDayResetsAt: Date?
}
final class OAuthUsageFetcher {
    func fetch() async throws -> OfficialUsage
}
final class UsageEngine {
    func computeSnapshot(query: UsageQuery) async -> UsageSnapshot  // never throws; on total failure returns snapshot with percentLeft 100? NO — see below
}
```
`UsageEngine.computeSnapshot` behavior: build from the query's source; `officialAPI` falls back
to `tokenCounts` on error (prefix sourceLabel). If JSONL scanning itself fails, return a snapshot
with `percentLeft = 0/0` impossible — instead set `usedDisplay = "no data"`, `percentLeft = 100`.
Format `usedDisplay`/`budgetDisplay` nicely: `$12.34` / `$35.00` for cost, `8.2M` / `50M tok` for
tokens, `37% used` / `official limit` for officialAPI.

```swift
// session-core
final class SessionMonitor {
    func loadActiveSessions() -> [SessionInfo]   // sorted by updatedAt desc
}
final class CapabilityScanner {
    func scan(cwd: String) -> SessionCapabilities
}
```
`SessionMonitor`: read every `~/.claude/sessions/*.json`; fields:
`{"pid":123,"sessionId":"...","cwd":"/path","name":"my-project-3f","status":"idle",
  "updatedAt":<ms-epoch>,"version":"2.1.201","kind":"interactive"}`.
A session is **active** iff its `pid` is alive (`kill(pid, 0) == 0`). Skip unparseable files.
`SessionInfo.id` = sessionId, name = name, status = status.

`CapabilityScanner.scan(cwd:)`:
- **Skills**: `<cwd>/.claude/skills/*/SKILL.md` (source "project") and `~/.claude/skills/*/SKILL.md`
  (source "user") — parse YAML frontmatter between `---` lines for `name:` and `description:`
  (naive line-based parsing is fine; use directory name if `name:` missing; truncate description ~160 chars).
- **Hooks**: merge `hooks` object from `~/.claude/settings.json` (source "user"),
  `<cwd>/.claude/settings.json` (source "project"), `<cwd>/.claude/settings.local.json`
  (source "local"). Schema: `{"hooks": {"PreToolUse": [{"matcher":"Bash","hooks":[{"type":"command","command":"..."}]}], ...}}`
  → one HookInfo per inner command with event = outer key.
- **Subagents**: `<cwd>/.claude/agents/*.md` (project) + `~/.claude/agents/*.md` (user) —
  frontmatter `name:`/`description:` like skills, filename stem as fallback name.

```swift
// pill-ui
@MainActor final class PillModeController {
    init(appState: AppState)
    func activate()    // create status item if needed, show
    func deactivate()  // remove status item, close popover
}
```
Pill: `NSStatusItem` (variableLength) hosting an `NSHostingView` with a Capsule fill
`#D97757` (shift to red `#C93A2E` when percentLeft < 10), white bold rounded 12pt text
`"63%"` (`"–"` when snapshot nil). Height ~20 inside the 24pt menu bar. Button click toggles
an `NSPopover` (transient) with `DropdownView`: header (big % left + progress bar + window/source
labels + resets-at), sessions count, and `SettingsView` (Form/GroupBox, ~340pt wide):
 - Picker: usage source (three options, help text)
 - Picker: window (5-hour / weekly)
 - Picker: plan preset (Pro / Max 5× / Max 20× / Custom) + editable budget fields when Custom
 - TextField+Stepper: cost multiplier (0.05...1.0...N, format %.2f) with caption
   "Enterprise discount multiplier applied to estimated cost"
 - **Advanced**: Toggle "Notch mode (Dynamic Island)" → sets `settings.displayMode = .notch`
 - Refresh interval slider (10–120 s); "Refresh now" button; "Quit" button (NSApp.terminate)

```swift
// notch-ui
@MainActor final class NotchModeController {
    init(appState: AppState)
    func activate()
    func deactivate()
}
```
Panel: borderless, `.nonactivatingPanel`, level `.statusBar`, clear background, no shadow,
`collectionBehavior [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`, on the screen with
`safeAreaInsets.top > 0` (else `NSScreen.main`, fake notch height 32).
Geometry: `notchHeight = max(screen.safeAreaInsets.top, 32)`;
`notchWidth = screen.frame.width - auxiliaryTopLeftArea.width - auxiliaryTopRightArea.width`
(fallback 200). Collapsed frame: `notchWidth + 2*76` wide × notchHeight tall, top-centered
(`y = screen.frame.maxY - h`). Expanded: 660 × 250, top-centered, animate with
`NSAnimationContext` (`window.animator().setFrame`, duration 0.25, ease). Keep the top edge
glued to the screen top.
Collapsed content: black shape (NotchShape: square top corners, rounded bottom corners r=10)
spanning full width; HStack: left wing = ClaudeLogo (orange, ~16pt, this is the click target
to expand), center spacer of notchWidth, right wing = % text (white, semibold, monospaced digits).
Expanded content: same black shape (bottom radius 24); layout:
`HStack { left tab rail (Skills/Hooks/Subagents vertical buttons, orange highlight for selection)
 | center session card (session name, abbreviated cwd, status dot+label, ‹ › chevron buttons calling
   appState.selectPreviousSession()/selectNextSession(), "n of m") | right: ScrollView list of
   the selected tab's items from appState.capabilities (name bold + description caption, 1-2 lines) }`.
Also show the % left small in the expanded top-right. Click on logo collapses again; clicking
anywhere outside the panel collapses (global+local mouse-down event monitors, removed on deactivate).
Empty states: "No active sessions" / "No skills found" etc.

## Refresh & wiring (already implemented in AppState — for reference)
- `AppState.start()` runs a loop: `refreshNow()` every `settings.refreshSeconds`.
- Settings changes debounce → `refreshNow()`.
- `selectedSessionIndex` changes → `capabilities` rescanned for the selected session's cwd.
- UI observes `appState` (`@ObservedObject`) and `appState.settings`.

## Style
- Follow existing code style of the foundation files (4-space indent, no header comments).
- Conservative, well-established APIs only (macOS 14 SDK). No async lets in UI, no new-in-26 APIs.
- Never crash on malformed input: all disk/JSON parsing wrapped, skip bad entries.
- Do NOT run `swift build` (integration is done centrally); write code that compiles cleanly.
