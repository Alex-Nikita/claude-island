import SwiftUI
import AppKit

// Settings inside the island: usage overview + section nav on the left,
// the shared SettingsView form (one section at a time) on the right.
struct IslandSettingsPane: View {
    @ObservedObject var appState: AppState
    @ObservedObject var uiModel: NotchUIModel

    @State private var section: SettingsSection = .usage

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    IslandActionButton("‹") { uiModel.showingSettings = false }
                    Text("Settings")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                usageOverview
                Spacer()
                sectionNav
                Spacer()
                    .frame(height: 2)
                IslandActionButton("Pill mode") { appState.settings.displayMode = .pill }
                IslandActionButton("Quit") { NSApp.terminate(nil) }
            }
            .frame(width: 230, alignment: .leading)
            ScrollView {
                SettingsView(
                    appState: appState,
                    settings: appState.settings,
                    showsActionRow: false,
                    visibleSection: section
                )
                .frame(width: 440)
                .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.colorScheme, .dark)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sectionNav: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(SettingsSection.allCases) { candidate in
                Button {
                    section = candidate
                } label: {
                    Text(candidate.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(section == candidate ? .white : .gray)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(section == candidate ? Color.claudeOrange : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 120)
    }

    // The same at-a-glance summary the pill dropdown leads with, in island
    // colors: big % left, a progress bar, budget and reset details. Both
    // derive from appState.summary, so they can't drift apart.
    @ViewBuilder
    private var usageOverview: some View {
        let summary = appState.summary
        VStack(alignment: .leading, spacing: 7) {
            if let snapshot = appState.snapshot {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(summary.headline.number)
                        .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundColor(snapshot.isLowBudget ? appState.colors.low : .claudeOrange)
                    Text(summary.headline.suffix)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(.gray)
                }
                if let fraction = summary.usedFraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(snapshot.isLowBudget ? appState.colors.low : Color.claudeOrange)
                }
                if let usedLine = summary.usedOfBudgetLine {
                    Text(usedLine)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                }
                if let metaLine = summary.metaLine {
                    Text(metaLine)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .lineLimit(2)
                }
                if let resetsAt = snapshot.resetsAt {
                    (Text("Resets in ") + Text(resetsAt, style: .relative))
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                HStack(spacing: 5) {
                    (Text("Updated ") + Text(snapshot.updatedAt, style: .relative) + Text(" ago"))
                        .font(.caption)
                        .foregroundColor(.gray)
                    refreshIcon
                }
            } else {
                Text("No usage data yet")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                HStack(spacing: 5) {
                    Text("Waiting for the first refresh…")
                        .font(.caption)
                        .foregroundColor(.gray)
                    refreshIcon
                }
            }
            Divider()
                .overlay(Color.gray.opacity(0.4))
                .padding(.vertical, 2)
            Text(appState.sessionCountLine)
                .font(.caption)
                .foregroundColor(.gray)
        }
    }

    @ViewBuilder
    private var refreshIcon: some View {
        if appState.isRefreshing {
            ProgressView()
                .controlSize(.mini)
                .environment(\.colorScheme, .dark)
        } else {
            Button {
                appState.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.gray)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Refresh now")
        }
    }
}
