import AppKit
import SwiftUI

// Sections the notch settings sidebar and the pill dropdown navigate
// individually.
enum SettingsSection: String, CaseIterable, Identifiable {
    case usage = "Usage"
    case display = "Display"
    case accessibility = "Accessibility"
    case app = "App"
    case about = "About"

    var id: String { rawValue }
}

@MainActor
struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var settings: AppSettings
    // The notch settings pane provides its own Refresh/Quit controls.
    var showsActionRow: Bool = true
    // nil = stacked (pill popover); a section = just that one (notch sidebar).
    var visibleSection: SettingsSection?
    // Default false, refreshed in onAppear: a @State default expression runs
    // on EVERY struct init (2s poll re-renders), and isInstalled does file IO.
    @State private var hookInstalled = false
    @State private var hookError: String?
    @State private var answerInstalled = false
    @State private var answerError: String?

    private static let budgetFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = true
        return formatter
    }()

    private static let multiplierFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch visibleSection {
            case .none:
                usageGroup
                Divider()
                displayGroup
                Divider()
                accessibilityGroup
                Divider()
                appGroup
                Divider()
                aboutGroup
            case .usage:
                usageGroup
            case .display:
                displayGroup
            case .accessibility:
                accessibilityGroup
            case .app:
                appGroup
            case .about:
                aboutGroup
            }
        }
    }

    private var aboutGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    ClaudeLogo()
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(AppInfo.name)
                            .font(.headline)
                        Text("Version \(AppInfo.version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("A menu-bar / notch meter for your Claude usage, sessions, and capabilities.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                if let profile = URL(string: AppInfo.gitHubProfileURL) {
                    HStack(spacing: 4) {
                        Text("Made by \(AppInfo.author)")
                            .font(.caption)
                        Link("@\(AppInfo.gitHubHandle)", destination: profile)
                            .font(.caption)
                    }
                }
                if let repo = URL(string: AppInfo.repositoryURL) {
                    HStack(spacing: 4) {
                        Text("Source & issues")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Link("github.com/\(AppInfo.gitHubHandle)/claude-island", destination: repo)
                            .font(.caption)
                    }
                }
                Text("Licensed under \(AppInfo.license). Not affiliated with Anthropic.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        } label: {
            sectionLabel("About")
        }
    }

    private var usageGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $settings.mode) {
                    ForEach(SettingsMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if settings.mode == .detected {
                    detectedSection
                } else {
                    customSection
                }
            }
            .padding(4)
        } label: {
            sectionLabel("Usage")
        }
    }

    private var displayGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Unit", selection: $settings.displayUnit) {
                    ForEach(DisplayUnit.allCases) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Direction", selection: $settings.percentDisplay) {
                    ForEach(PercentDisplay.allCases) { display in
                        Text(settings.displayUnit == .dollars
                             ? (display == .left ? "$ left" : "$ used")
                             : display.title)
                            .tag(display)
                    }
                }
                .pickerStyle(.segmented)
                Text(displayCaption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        } label: {
            sectionLabel("Display")
        }
    }

    private var accessibilityGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Picker("", selection: $settings.colorVision) {
                        ForEach(ColorVision.allCases) { vision in
                            Text(vision.shortTitle).tag(vision)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(colorVisionCaption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Status symbols", isOn: $settings.statusSymbols)
                        .disabled(settings.colorVision == .monochrome)
                    Text(settings.colorVision == .monochrome
                         ? "Always on with the monochrome palette — lightness alone can't carry five states."
                         : "Adds glyphs to the status dots (▶ working, ! waiting, ⏸ idle, ⚡ active) so state never relies on color alone.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        } label: {
            sectionLabel("Accessibility")
        }
    }

    private var appGroup: some View {
        GroupBox {
            advancedSection
                .padding(4)
        } label: {
            sectionLabel("App")
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }

    private var colorVisionCaption: String {
        switch settings.colorVision {
        case .standard:
            return "Standard state colors: green working, beige waiting, red for low budget."
        case .deuteranopia:
            return "Deuteranopia (green-blind): blue/amber palette — hues that stay distinct without green perception."
        case .protanopia:
            return "Protanopia (red-blind): blue/yellow palette avoiding deep reds, which appear near-black."
        case .tritanopia:
            return "Tritanopia (blue-blind): green/red palette — the axis that survives when blue/yellow collapses."
        case .monochrome:
            return "Lightness-only palette; status symbols are enabled automatically."
        }
    }

    private var displayCaption: String {
        switch (settings.displayUnit, settings.percentDisplay) {
        case (.percent, .left):
            return "The pill and island count down: 63% means 63% of your budget remains."
        case (.percent, .used):
            return "The pill and island count up: 37% means you've consumed 37% of your budget."
        case (.dollars, .left):
            return "Shows your remaining balance in dollars. Estimated from per-model pricing unless your account has real credit limits."
        case (.dollars, .used):
            return "Shows spend in the window in dollars. Estimated from per-model pricing unless your account has real credit limits."
        }
    }

    // Everything read from the logged-in Claude Code install: the plan from
    // the keychain credential, the real limits from the usage endpoint.
    // Consent-first: nothing touches the keychain until the user connects.
    @ViewBuilder
    private var detectedSection: some View {
        if !settings.connectAccount {
            Text("Runs on local token estimates. Connect your Claude account to see your real limits — session, weekly, and per-model — straight from Anthropic.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Connect Claude account…") { appState.connectAccount() }
            Text("Reads the Claude Code sign-in from your keychain and sends it only to api.anthropic.com to fetch usage. macOS will ask for permission — choose “Always Allow” to avoid repeat prompts. Disconnect anytime.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if !appState.accountAccessAuthorized {
            // A blessing exists (this state is unreachable without one) but
            // this launch couldn't reconnect silently — either the app was
            // rebuilt (macOS treats it as new) or the grant wasn't durable.
            // Only an explicit press may trigger the keychain prompt.
            HStack(spacing: 6) {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.secondary)
                Text("Real limits paused")
                    .font(.callout)
                    .fontWeight(.medium)
                Spacer()
                Button("Disconnect") { appState.disconnectAccount() }
                    .controlSize(.small)
            }
            Button("Connect Claude account…") { appState.authorizeAccountAccess() }
            Text(appState.currentBuildBlessed
                 ? "macOS didn't release the sign-in automatically this time. Approve with “Always Allow” and future launches reconnect on their own."
                 : "The app changed since you last approved it (macOS treats an updated app as new), so it needs one fresh approval. Choose “Always Allow” and future launches reconnect on their own.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if let account = appState.detectedAccount {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Connected — \(account.planLabel)")
                    .font(.callout)
                    .fontWeight(.medium)
                Spacer()
                Button("Disconnect") { appState.disconnectAccount() }
                    .controlSize(.small)
            }
            Text("Plan and limits come from your Claude Code login. Pick which limit the pill and island headline.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            // A degraded fetch shouldn't be a mystery: name the reason
            // (expired token, HTTP status, keychain denial) right here.
            if let fetchError = appState.snapshot?.fetchErrorDescription {
                Text("Last fetch failed: \(fetchError)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if let limits = appState.snapshot?.officialLimits, !limits.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    limitChoiceRow(
                        selected: settings.selectedLimitID == nil,
                        action: { settings.selectedLimitID = nil }
                    ) {
                        Text("Tightest limit (auto)")
                            .font(.caption)
                        Spacer()
                    }
                    ForEach(limits) { limit in
                        limitChoiceRow(
                            selected: settings.selectedLimitID == limit.id,
                            action: { settings.selectedLimitID = limit.id }
                        ) {
                            limitRow(limit)
                        }
                    }
                }
                .padding(.top, 2)
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("Couldn't read the Claude Code sign-in")
                    .font(.callout)
                    .fontWeight(.medium)
                Spacer()
                Button("Disconnect") { appState.disconnectAccount() }
                    .controlSize(.small)
            }
            Text("The keychain prompt may have been denied, or Claude Code isn't signed in (run /login). Retrying on each refresh; local estimates are used meanwhile.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let fetchError = appState.snapshot?.fetchErrorDescription {
                Text("Last fetch failed: \(fetchError)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    // Radio-style wrapper: clicking a limit pins it as the headline.
    private func limitChoiceRow<Content: View>(
        selected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button {
            action()
            appState.refreshNow()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.claudeOrange : Color.secondary)
                content()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func limitRow(_ limit: OfficialLimit) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(limit.label)
                    .font(.caption)
                    .lineLimit(1)
                if let resetsAt = limit.resetsAt {
                    (Text("resets in ") + Text(resetsAt, style: .relative))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 140, alignment: .leading)
            ProgressView(value: limit.percentUsed / 100)
                .progressViewStyle(.linear)
                .tint(limit.severity == "normal" ? Color.claudeOrange : appState.colors.low)
            Text("\(Int(limit.percentUsed.rounded()))%")
                .font(.caption.monospacedDigit())
                .frame(width: 34, alignment: .trailing)
            if limit.isActive {
                Text("active")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.claudeOrange)
            }
        }
    }

    @ViewBuilder
    private var customSection: some View {
        Picker("Account", selection: $settings.accountKind) {
            ForEach(AccountKind.allCases) { kind in
                Text(kind.title).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        Text(settings.accountKind == .subscription
             ? "Pro, Max, Team, and seat-based Enterprise — all meter rolling 5-hour and weekly windows."
             : "Console/API billing or usage-based Enterprise — no usage windows; spend counts against a monthly budget.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        if settings.accountKind == .usageBased {
            usageBasedSection
        } else {
            subscriptionSection
        }
    }

    @ViewBuilder
    private var subscriptionSection: some View {
        Picker("Source", selection: $settings.source) {
            ForEach(UsageSource.allCases) { source in
                Text(source.title)
                    .help(source.help)
                    .tag(source)
            }
        }
        .pickerStyle(.radioGroup)
        // Actively picking Official API is itself the consent gesture that
        // arms this run's keychain gate.
        .onChange(of: settings.source) { _, newSource in
            if newSource == .officialAPI { appState.authorizeAccountAccess() }
        }
        // Persisted Official API selection from an earlier run: unarmed
        // until asked, exactly like the Detected-mode connect flow.
        if settings.source == .officialAPI, !appState.accountAccessAuthorized {
            Button("Load real limits…") { appState.authorizeAccountAccess() }
            Text("Reads the Claude Code keychain sign-in — asked only when you press this, never at launch.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        Picker("Window", selection: $settings.window) {
            ForEach(UsageWindow.subscriptionWindows) { window in
                Text(window.title).tag(window)
            }
        }
        .pickerStyle(.segmented)
        Picker("Plan", selection: $settings.planPreset) {
            ForEach(PlanPreset.allCases) { preset in
                Text(preset.title).tag(preset)
            }
        }
        .pickerStyle(.menu)
        if settings.planPreset == .custom {
            customBudgetFields
        }
        if settings.source != .costEstimate {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Weight cache tokens by price", isOn: $settings.weightCacheTokens)
                    .font(.caption)
                Text("Counts cache reads at 0.1×, cache writes at 1.25–2× — closer to how limits are metered")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        multiplierRow
    }

    // Usage-based accounts: Anthropic's usage endpoint returns nothing for
    // them, so spend is estimated locally from per-model pricing against a
    // monthly calendar budget (resets on the 1st, like Anthropic's own
    // billing and spend caps).
    @ViewBuilder
    private var usageBasedSection: some View {
        budgetField("Monthly budget ($)", value: $settings.customCostBudgetMonthly)
        Text("Estimated locally from your transcripts × per-model pricing; resets with the calendar month. Match it to your Console workspace or per-user spend limit.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        multiplierRow
    }

    // Official API falls back to token counts on failure, so its token budget stays editable.
    @ViewBuilder
    private var customBudgetFields: some View {
        if settings.source == .costEstimate {
            budgetField("5-hour cost budget ($)", value: $settings.customCostBudget5h)
            budgetField("Weekly cost budget ($)", value: $settings.customCostBudgetWeekly)
        }
        if settings.source == .tokenCounts || settings.source == .officialAPI {
            budgetField("5-hour token budget", value: $settings.customTokenBudget5h)
            budgetField("Weekly token budget", value: $settings.customTokenBudgetWeekly)
        }
    }

    private func budgetField(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
                .font(.caption)
            Spacer()
            TextField("", value: value, formatter: Self.budgetFormatter)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 110)
        }
    }

    private var multiplierRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Cost multiplier")
                    .font(.caption)
                Spacer()
                TextField("", value: $settings.costMultiplier, formatter: Self.multiplierFormatter)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                Stepper("", value: $settings.costMultiplier, in: 0.05...2.0, step: 0.05)
                    .labelsHidden()
            }
            Text("Enterprise discount multiplier applied to estimated cost")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Notch mode (Dynamic Island)", isOn: $settings.notchModeEnabled)
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Auto-expand island on prompts", isOn: $settings.autoExpandOnPrompt)
                Text("Pops the island open whenever a session is waiting on a question, plan, or permission.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Minimize island on click-away", isOn: $settings.collapseOnClickAway)
                Text("Collapses the expanded island when you click anywhere else on the screen. Off keeps it open until you collapse it yourself.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Hide Claude Island's own hooks", isOn: $settings.hideIslandHooks)
                Text("Keeps the island's capture and answer hooks out of the Hooks tab, so only yours are listed.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Session insights (Claude Code hook)", isOn: hookBinding)
                Text(hookError ?? "Statusline + prompt capture: fills the Context page and shows the exact question, plan, or permission a session is waiting on. Read-only. Running sessions pick it up automatically.")
                    .font(.caption2)
                    .foregroundStyle(hookError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
            }
            .onAppear {
                hookInstalled = HookCapture.isInstalled
                answerInstalled = HookCapture.isClickToAnswerInstalled
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Click-to-answer from the island", isOn: answerBinding)
                    .disabled(!hookInstalled && !answerInstalled)
                Text(answerError ?? "Answer questions and permission prompts by clicking the island — your click races the terminal dialog. On managed or enterprise seats, check your org's policy first (see SECURITY.md). Requires Session insights.")
                    .font(.caption2)
                    .foregroundStyle(answerError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
            }
            HStack {
                Text("Refresh every")
                    .font(.caption)
                Slider(value: $settings.refreshSeconds, in: AppSettings.refreshRange, step: 5)
                Text("\(Int(settings.refreshSeconds)) s")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
            if showsActionRow {
                HStack {
                    Button("Refresh now") { appState.refreshNow() }
                    if appState.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }
            }
        }
    }

    private var hookBinding: Binding<Bool> {
        Binding(
            get: { hookInstalled },
            set: { wanted in
                do {
                    if wanted {
                        try HookCapture.installCapture()
                    } else {
                        // Turning insights off removes everything — the
                        // answerer can't run without its capture half.
                        try HookCapture.uninstall()
                    }
                    hookError = nil
                } catch {
                    hookError = "Couldn't update ~/.claude/settings.json: \(error.localizedDescription)"
                }
                hookInstalled = HookCapture.isInstalled
                answerInstalled = HookCapture.isClickToAnswerInstalled
            }
        )
    }

    private var answerBinding: Binding<Bool> {
        Binding(
            get: { answerInstalled },
            set: { wanted in
                do {
                    if wanted {
                        try HookCapture.installAnswerer()
                    } else {
                        try HookCapture.uninstallAnswerer()
                    }
                    answerError = nil
                } catch {
                    answerError = "Couldn't update ~/.claude/settings.json: \(error.localizedDescription)"
                }
                hookInstalled = HookCapture.isInstalled
                answerInstalled = HookCapture.isClickToAnswerInstalled
            }
        )
    }
}
