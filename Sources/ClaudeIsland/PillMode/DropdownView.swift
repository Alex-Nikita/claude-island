import SwiftUI
import AppKit

// The pill's popover. The root stays glanceable: usage summary, the notch
// toggle (deliberately inline — it's the mode switch), and one row per
// settings section. Everything else lives one drill-in away so the popover
// never reads as a wall of controls.
@MainActor
struct DropdownView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var settings: AppSettings

    @State private var openSection: SettingsSection?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let section = openSection {
                sectionPage(section)
            } else {
                header
                Divider()
                Toggle("Notch mode (Dynamic Island)", isOn: $settings.notchModeEnabled)
                Divider()
                VStack(spacing: 2) {
                    ForEach(SettingsSection.allCases) { section in
                        sectionRow(section)
                    }
                }
                Divider()
                HStack {
                    Spacer()
                    Button("Quit Claude Island") { NSApp.terminate(nil) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
        // The popover's hosting controller outlives a close; reopening
        // should always land on the compact root, not a stale drill-in.
        .onDisappear { openSection = nil }
    }

    // MARK: - Root

    // The same summary the island settings pane leads with — both derive
    // from appState.summary, so they can't drift apart.
    @ViewBuilder
    private var header: some View {
        let summary = appState.summary
        VStack(alignment: .leading, spacing: 6) {
            if let snapshot = appState.snapshot {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(summary.headline.number)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(summary.headline.suffix)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                if let fraction = summary.usedFraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(snapshot.isLowBudget ? appState.colors.low : Color.claudeOrange)
                }
                if let metaLine = summary.metaLine {
                    Text(metaLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let usedLine = summary.usedOfBudgetLine {
                    Text(usedLine)
                        .font(.callout)
                }
                if let resetsAt = snapshot.resetsAt {
                    (Text("Resets in ") + Text(resetsAt, style: .relative))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    (Text("Updated ") + Text(snapshot.updatedAt, style: .relative) + Text(" ago"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    refreshIcon
                }
            } else {
                Text("No usage data yet")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                HStack(spacing: 5) {
                    Text("Waiting for the first refresh…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    refreshIcon
                }
            }
            Text(appState.sessionCountLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var refreshIcon: some View {
        if appState.isRefreshing {
            ProgressView()
                .controlSize(.mini)
        } else {
            Button {
                appState.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Refresh now")
        }
    }

    private func sectionRow(_ section: SettingsSection) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { openSection = section }
        } label: {
            HStack(spacing: 6) {
                Text(section.rawValue)
                    .font(.callout)
                Spacer()
                Text(sectionDetail(section))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // One-line current-value hint per row, so the compact root still
    // answers "how is this configured" without opening anything.
    private func sectionDetail(_ section: SettingsSection) -> String {
        switch section {
        case .usage:
            return settings.mode == .detected && settings.connectAccount
                ? (appState.detectedAccount?.planLabel ?? SettingsMode.detected.title)
                : settings.mode.title
        case .display:
            let direction = settings.percentDisplay == .left ? "left" : "used"
            return settings.displayUnit == .dollars ? "$ \(direction)" : "% \(direction)"
        case .accessibility:
            var parts = [settings.colorVision.shortTitle]
            if settings.statusSymbols || settings.colorVision == .monochrome {
                parts.append("symbols")
            }
            return parts.joined(separator: " · ")
        case .app:
            return "refresh \(Int(settings.refreshSeconds))s"
        case .about:
            return "v\(AppInfo.version)"
        }
    }

    // MARK: - Drill-in page

    private func sectionPage(_ section: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { openSection = nil }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Back")
                            .font(.callout)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
                Text(section.rawValue)
                    .font(.headline)
                Spacer()
                // Mirror the back control's width so the title stays centered.
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                    Text("Back").font(.callout)
                }
                .hidden()
            }
            SettingsView(
                appState: appState,
                settings: settings,
                showsActionRow: false,
                visibleSection: section
            )
        }
    }
}
