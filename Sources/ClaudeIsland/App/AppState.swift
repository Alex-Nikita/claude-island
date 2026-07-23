import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    let settings: AppSettings

    @Published var snapshot: UsageSnapshot?
    // Result of the GitHub release check; drives the About "update available"
    // row and the small dot on the Settings entry points.
    @Published var updateStatus: UpdateStatus = .unknown
    // True while a manual "Check now" is in flight, for button feedback.
    @Published private(set) var isCheckingUpdate = false
    @Published var sessions: [SessionInfo] = []
    @Published var selectedSessionIndex: Int = 0 {
        didSet { rescanCapabilities() }
    }
    @Published var capabilities: SessionCapabilities?
    @Published var isRefreshing = false
    @Published var detectedAccount: DetectedAccount?
    // Keychain access is armed per launch by an explicit user action —
    // launching must never surprise with a credentials prompt, even when
    // the connect preference is persisted from an earlier run.
    @Published private(set) var accountAccessAuthorized = false
    // True only while an explicit Connect / Try again attempt is in flight —
    // including the stretch where the fetch is blocked behind the macOS
    // keychain password prompt. Distinct from isRefreshing (which also flips
    // on background polls) so the UI can show "Connecting…" without flickering
    // it on every periodic refresh.
    @Published private(set) var isConnecting = false
    // Identity of the running binary — the thing keychain grants bind to.
    let currentBuildHash = BuildIdentity.currentCodeHash()

    // True when the user's blessing was granted on THIS binary (a silent
    // reconnect is plausible); false after a rebuild (approval needed).
    var currentBuildBlessed: Bool {
        settings.authorizedBuildHash != nil && settings.authorizedBuildHash == currentBuildHash
    }
    // Incremented when any session transitions working -> idle ("job done").
    @Published private(set) var completionPulseCount = 0

    private let engine = UsageEngine()
    private let updateChecker = UpdateChecker()
    private let monitor = SessionMonitor()
    private let scanner = CapabilityScanner()
    private var refreshTask: Task<Void, Never>?
    private var sessionPollTask: Task<Void, Never>?
    private var updateCheckTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(settings: AppSettings) {
        self.settings = settings
    }

    var colors: SemanticColors {
        .palette(for: settings.colorVision)
    }

    // Monochrome vision gets symbols unconditionally — lightness alone
    // can't carry five states.
    var symbolsEnabled: Bool {
        settings.statusSymbols || settings.colorVision == .monochrome
    }

    var selectedSession: SessionInfo? {
        guard sessions.indices.contains(selectedSessionIndex) else { return nil }
        return sessions[selectedSessionIndex]
    }

    // Folder name of the selected session's project, for capability badges.
    var selectedProjectName: String? {
        selectedSession.map { URL(fileURLWithPath: $0.cwd).lastPathComponent }
    }

    // All user-facing readings of the snapshot derive from here, so the
    // pill, dropdown, and island can never drift apart.
    var summary: UsageSummary {
        UsageSummary(snapshot: snapshot,
                     unit: settings.displayUnit,
                     direction: settings.percentDisplay)
    }

    // The number shown everywhere compact (pill, notch wing, expanded
    // corner) — unit and direction follow the Display settings.
    var percentLeftText: String { summary.compactText }

    // Long form for tooltips and accessibility.
    var percentDescription: String { summary.accessibilityDescription }

    // A newer GitHub release exists — flags the About row and the Settings dot.
    var hasUpdate: Bool { updateStatus.release != nil }

    var sessionCountLine: String {
        switch sessions.count {
        case 0: return "No active Claude Code sessions"
        case 1: return "1 active Claude Code session"
        case let n: return "\(n) active Claude Code sessions"
        }
    }

    var isAnySessionBusy: Bool {
        sessions.contains { $0.isActivelyWorking }
    }

    var needsUserAttention: Bool {
        DebugFlags.forceAttention || sessions.contains { $0.needsAttention }
    }

    // Prefer the user's selected session when it needs attention, so with
    // several sessions waiting the chevrons still choose which prompt shows.
    var attentionSession: SessionInfo? {
        if let selected = selectedSession, selected.needsAttention { return selected }
        return sessions.first { $0.needsAttention }
    }

    func start() {
        Task.detached { HookCapture.pruneStaleFiles() }
        // Silent reconnect: whenever a grant was ever recorded, probe with
        // UI forbidden — success arms without any prompt. With a stable
        // signing identity the keychain grant survives rebuilds, so even a
        // new binary reconnects silently; if the grant doesn't cover us
        // (ad-hoc rebuild, revoked access) the probe fails silently and
        // the paused state waits for the explicit click.
        if settings.connectAccount, settings.authorizedBuildHash != nil {
            Task { [weak self] in
                guard let self else { return }
                if await self.engine.authorizeAccountAccessIfAlreadyTrusted() {
                    self.accountAccessAuthorized = true
                    await self.refresh()
                }
            }
        }
        // Update check: once at launch, then every 6h while running, so a
        // long-lived menu-bar app notices a release without a restart. The
        // checker's 6h cache keeps GitHub hits to one per interval; when the
        // user has it off, the loop skips the network but keeps ticking cheaply.
        updateCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.settings.checkForUpdates {
                    let status = await self.updateChecker.check(currentVersion: AppInfo.version)
                    self.updateStatus = status
                }
                try? await Task.sleep(nanoseconds: UInt64(6 * 60 * 60) * 1_000_000_000)
            }
        }
        if DebugFlags.simulatePulse {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.completionPulseCount += 1
            }
        }
        settings.objectWillChange
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshNow() }
            .store(in: &cancellables)

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let seconds = await MainActor.run {
                    self?.settings.refreshSeconds ?? AppSettings.defaultRefreshSeconds
                }
                let clamped = max(AppSettings.refreshRange.lowerBound, seconds)
                try? await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
            }
        }
        // Sessions poll fast (a handful of small file stats) so activity
        // animations react in ~2s; the usage scan stays on the slow loop.
        sessionPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollSessions()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        sessionPollTask?.cancel()
        sessionPollTask = nil
        updateCheckTask?.cancel()
        updateCheckTask = nil
    }

    func refreshNow() {
        Task { await refresh() }
    }

    /// The About "Check now" button: force a fresh GitHub check that bypasses
    /// the 6h cache, with a brief in-flight state for the button.
    func checkForUpdatesNow() {
        guard !isCheckingUpdate else { return }
        isCheckingUpdate = true
        Task { [weak self] in
            guard let self else { return }
            let status = await self.updateChecker.forceCheck(currentVersion: AppInfo.version)
            self.updateStatus = status
            self.isCheckingUpdate = false
        }
    }

    /// The Connect button: remember the preference AND arm this run.
    func connectAccount() {
        settings.connectAccount = true
        authorizeAccountAccess()
    }

    func disconnectAccount() {
        settings.connectAccount = false
        settings.authorizedBuildHash = nil
        refreshNow()
    }

    /// Arms the keychain gate, remembers this build as blessed (so its
    /// future launches reconnect silently), then refreshes with real
    /// limits. Only ever called from explicit user gestures (Connect,
    /// Load real limits, actively picking the Official API source).
    func authorizeAccountAccess() {
        accountAccessAuthorized = true
        isConnecting = true
        settings.authorizedBuildHash = currentBuildHash
        Task {
            await engine.authorizeAccountAccess()
            await refresh()
            isConnecting = false
        }
    }

    func selectNextSession() {
        guard !sessions.isEmpty else { return }
        selectedSessionIndex = (selectedSessionIndex + 1) % sessions.count
    }

    func selectPreviousSession() {
        guard !sessions.isEmpty else { return }
        selectedSessionIndex = (selectedSessionIndex - 1 + sessions.count) % sessions.count
    }

    private var refreshInFlight = false
    private var refreshQueued = false

    private func refresh() async {
        // Serialize: a slow scan finishing late must not overwrite the
        // snapshot a newer refresh already published.
        if refreshInFlight {
            refreshQueued = true
            return
        }
        refreshInFlight = true
        isRefreshing = true
        defer {
            isRefreshing = false
            refreshInFlight = false
            if refreshQueued {
                refreshQueued = false
                refreshNow()
            }
        }

        // Debug aid: fake a no-caps account to preview the ∞ presentation.
        // Must short-circuit BEFORE the engine runs — the real fetch could
        // block on a keychain prompt and the mock would never appear.
        if DebugFlags.mockUnlimited {
            snapshot = UsageSnapshot(
                percentLeft: 100,
                usedDisplay: "$142.10 spent",
                budgetDisplay: "unlimited",
                windowLabel: "No limits",
                sourceLabel: "Official API · no usage caps on this account",
                resetsAt: nil,
                updatedAt: Date(),
                officialLimits: [],
                isUnlimited: true,
                dollarsUsed: 142.10,
                dollarsBudget: nil
            )
            detectedAccount = DetectedAccount(
                subscriptionType: "enterprise",
                rateLimitTier: nil,
                planPreset: .custom
            )
            applySessions(await loadSessionsOffMain())
            rescanCapabilities()
            return
        }
        let query = settings.makeQuery()
        snapshot = await engine.computeSnapshot(query: query)
        // Keychain is touched only with explicit consent — reading the
        // credential raises a macOS prompt and grants token access. The
        // fetcher is an actor, so this hops off the main thread on its own.
        if settings.connectAccount {
            let account = await engine.detectAccount()
            detectedAccount = account
            // Equality guard: the didSet persists and pings objectWillChange,
            // which debounces into another refresh — only write real changes.
            if let preset = account?.planPreset, settings.detectedPlanPreset != preset {
                settings.detectedPlanPreset = preset
            }
        } else if detectedAccount != nil {
            detectedAccount = nil
        }
        applySessions(await loadSessionsOffMain())
        rescanCapabilities()
    }

    private func pollSessions() async {
        applySessions(await loadSessionsOffMain())
    }

    // The session scan stats every registry file and reads transcript tails
    // — never run it on the main actor (both the 2s poll and the refresh
    // loop go through here).
    private func loadSessionsOffMain() async -> [SessionInfo] {
        let monitor = self.monitor
        return await Task.detached { monitor.loadActiveSessions() }.value
    }

    private func applySessions(_ newSessions: [SessionInfo]) {
        if DebugFlags.logAttention,
           let s = newSessions.first(where: { $0.needsAttention }) {
            NSLog("attention session=%@ status=%@ prompt=%@",
                  s.name, s.status, s.pendingPrompt?.title ?? "NIL")
        }
        let previousID = selectedSession?.id
        // Pulse on busy -> idle by claimed status (not isActivelyWorking):
        // when the idle write lags, the spin stops on transcript staleness
        // first, but the completion still deserves its pulse when it lands.
        let previouslyBusy = Set(sessions.filter { $0.claimsBusy || $0.needsAttention }.map(\.id))
        sessions = newSessions
        let jobFinished = newSessions.contains {
            previouslyBusy.contains($0.id) && $0.state == .idle
        }
        if jobFinished {
            completionPulseCount += 1
        }
        if let previousID, let idx = newSessions.firstIndex(where: { $0.id == previousID }) {
            if idx != selectedSessionIndex { selectedSessionIndex = idx }
        } else if selectedSessionIndex >= newSessions.count {
            selectedSessionIndex = 0
        }
    }

    private func rescanCapabilities() {
        guard let session = selectedSession else {
            capabilities = nil
            return
        }
        let cwd = session.cwd
        Task.detached { [scanner] in
            let caps = scanner.scan(cwd: cwd)
            await MainActor.run { [weak self] in
                guard self?.selectedSession?.cwd == cwd else { return }
                self?.capabilities = caps
            }
        }
    }
}
