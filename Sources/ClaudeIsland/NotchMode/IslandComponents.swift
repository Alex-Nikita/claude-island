import SwiftUI

// Small building blocks shared by the island's screens.

/// Quiet gray text action ("Settings", "Quit", "‹").
struct IslandActionButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(.gray)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Round session-cycling chevron.
struct ChevronButton: View {
    let symbol: String
    let action: () -> Void

    init(_ symbol: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.islandChipFill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Stroked capsule for wizard navigation ("‹ Previous", "Next ›").
struct NavPill: View {
    let title: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(enabled ? .white : Color.gray.opacity(0.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().stroke(Color.white.opacity(enabled ? 0.3 : 0.12), lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// Breathing dot: pulses while the session works or waits on the user,
// sits still for idle/stale. Status text lives in the hover tooltip.
struct StatusDot: View {
    let color: Color
    let pulsing: Bool
    // Redundant encoding for color-vision deficiency: state readable by
    // glyph, not just hue.
    var symbol: String? = nil
    @State private var dimmed = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 5, weight: .black))
                    .foregroundColor(.black.opacity(0.8))
            }
        }
        .frame(width: symbol == nil ? 8 : 11, height: symbol == nil ? 8 : 11)
        .opacity(pulsing && dimmed ? 0.35 : 1)
        .scaleEffect(pulsing && dimmed ? 0.8 : 1)
        .animation(
            pulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
            value: dimmed
        )
        .onAppear { dimmed = pulsing }
        .onChange(of: pulsing) { _, nowPulsing in
            dimmed = nowPulsing
        }
    }
}

/// Capsule naming where a capability comes from.
struct SourceBadge: View {
    let source: String
    // The selected session's folder name, shown for project/local scopes.
    let projectName: String?

    var body: some View {
        let isIsland = source == "island"
        Text(Self.label(source, projectName: projectName))
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(isIsland ? .claudeOrange : .gray)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(isIsland ? Color.claudeOrange.opacity(0.16) : Color.white.opacity(0.1)))
    }

    // Scanner scope names ("project"/"user"/"local") are internal — badge
    // the actual project folder name and "Personal" instead.
    static func label(_ source: String, projectName: String?) -> String {
        var label: String
        switch source {
        case "project": label = projectName ?? "Project"
        case "local": label = (projectName ?? "Project") + " · local"
        case "user": label = "Personal"
        case "island": label = "✳ Claude Island"
        default: label = source
        }
        // Truncate in the string, not with a flexible frame — a maxWidth
        // frame stretches in HStacks with spare room, ballooning the pill.
        if label.count > 26 {
            label = label.prefix(12) + "…" + label.suffix(12)
        }
        return label
    }
}

// Centered empty state that teaches instead of shrugging: what this
// capability is, plus doors to the docs and Anthropic Academy.
struct CapabilityEmptyState: View {
    let symbol: String
    let title: String
    let blurb: String
    let docsURL: String

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundColor(.gray)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            Text(blurb)
                .font(.system(size: 11))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            HStack(spacing: 8) {
                learnLink("Learn more", url: docsURL)
                learnLink("Anthropic Academy", url: "https://anthropic.skilljar.com")
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .center)
    }

    private func learnLink(_ title: String, url: String) -> some View {
        Button {
            if let target = URL(string: url) {
                NSWorkspace.shared.open(target)
            }
        } label: {
            Text(title + " ↗")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.islandChipFill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct NothingActiveNote: View {
    var body: some View {
        Text("Nothing active right now")
            .font(.system(size: 12))
            .foregroundColor(.gray)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }
}

// Presentation mappings for a session's state, shared by the header, the
// session picker, and the decision pane.
extension SessionInfo {
    func statusColor(_ colors: SemanticColors) -> Color {
        if needsAttention { return colors.waiting }
        if isActivelyWorking { return colors.working }
        if state == .idle { return colors.idle }
        return .gray
    }

    /// Glyph for the state when symbol overlays are enabled.
    func statusSymbol(symbolsEnabled: Bool) -> String? {
        guard symbolsEnabled else { return nil }
        if needsAttention { return "exclamationmark" }
        if isActivelyWorking { return "play.fill" }
        if state == .idle { return "pause.fill" }
        return "minus"
    }

    var stateWord: String {
        if needsAttention { return "waiting" }
        if isActivelyWorking { return "working" }
        return status.lowercased()
    }

    func stateColor(_ colors: SemanticColors) -> Color {
        if needsAttention { return colors.waiting }
        if isActivelyWorking { return colors.working }
        return .gray
    }

    /// "Fable · xhigh · 34% context" — whichever parts the session reports.
    var runtimeLine: String? {
        var parts: [String] = []
        if let model = modelShortName { parts.append(model) }
        if let effort = effortLevel { parts.append(effort) }
        if let ctx = contextPercent { parts.append("\(ctx)% context") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension String {
    /// "~/Documents/app" — home-relative display for absolute paths.
    var abbreviatingHomeDirectory: String {
        let home = NSHomeDirectory()
        guard hasPrefix(home) else { return self }
        return "~" + dropFirst(home.count)
    }
}
