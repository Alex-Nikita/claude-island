import SwiftUI

// /context-style visual: a 100-cell grid (1 cell = 1% of the window)
// colored by the API-side composition, with a legend. The semantic split
// (system prompt/skills/messages) is /context-internal; what the API
// reports is cached context, fresh cache writes, and new input.
struct ContextScreenView: View {
    @ObservedObject var appState: AppState
    let session: SessionInfo
    @Binding var showSessionPicker: Bool
    let close: () -> Void

    // Constant chrome: centered title with the back action pinned left,
    // centered session cycler beneath — always present regardless of
    // whether the current session has context data.
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                HStack {
                    IslandActionButton("‹") { close() }
                        .padding(.leading, -10)
                    Spacer()
                }
                Text("Context")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
            HStack(spacing: 8) {
                ChevronButton("chevron.left") { appState.selectPreviousSession() }
                // Same dropdown as the main header — the title is a picker.
                Button {
                    showSessionPicker.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Text(session.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.gray)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundColor(.gray)
                            .rotationEffect(.degrees(showSessionPicker ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                ChevronButton("chevron.right") { appState.selectNextSession() }
            }
            .frame(maxWidth: 340)
            if let breakdown = session.contextBreakdown {
                contextPane(breakdown: breakdown)
            } else {
                Text("No context data for this session yet — it appears after its next status refresh.")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func contextPane(breakdown: ContextBreakdown) -> some View {
        let categories: [(color: Color, label: String, tokens: Double)] = [
            (.cacheReadPurple, "Cached context (read)", breakdown.cacheRead),
            (.claudeOrange, "Written to cache this turn", breakdown.cacheWrite),
            (Color.white.opacity(0.85), "Fresh input", breakdown.input),
        ]
        let size = max(breakdown.windowSize, 1)
        var cellColors: [Color] = []
        for category in categories where category.tokens > 0 {
            let cells = Int((category.tokens / size * 100).rounded())
            cellColors.append(contentsOf: Array(repeating: category.color, count: max(cells, 1)))
        }
        // Trim/pad so used cells match the authoritative percentage.
        let usedCells = min(100, Int(breakdown.usedPercent.rounded()))
        if cellColors.count > usedCells {
            cellColors = Array(cellColors.prefix(usedCells))
        } else if let last = cellColors.last {
            cellColors.append(contentsOf: Array(repeating: last, count: usedCells - cellColors.count))
        }

        // Header and session cycler live in body so they survive cycling
        // onto sessions without data — this pane is numbers only.
        return HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Int(breakdown.usedPercent.rounded()))%")
                    .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundColor(breakdown.isHighUsage ? appState.colors.waiting : .claudeOrange)
                Text("of \(Format.tokens(breakdown.windowSize)) context used")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(Format.tokens(breakdown.usedTokens)) used")
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                Text("\(Format.tokens(breakdown.freeTokens)) free")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                // Which brain fills this window — and how hard it thinks.
                if let model = session.model {
                    Text(model)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
                if let effort = session.effortLevel {
                    Text("effort: \(effort)")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }
                Spacer()
            }
            .frame(width: 130, alignment: .leading)
            .padding(.top, 2)

            HStack(alignment: .center, spacing: 20) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(11), spacing: 3), count: 20),
                    spacing: 3
                ) {
                    ForEach(0..<100, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(index < cellColors.count ? cellColors[index] : Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2.5)
                                    .stroke(Color.gray.opacity(index < cellColors.count ? 0 : 0.35), lineWidth: 1)
                            )
                            .frame(height: 11)
                    }
                }
                .frame(width: 20 * 11 + 19 * 3)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(categories.enumerated()), id: \.offset) { _, category in
                        if category.tokens > 0 {
                            legendRow(
                                color: category.color,
                                title: category.label,
                                detail: "\(Format.tokens(category.tokens)) · \(percentText(category.tokens / size * 100))"
                            )
                        }
                    }
                    legendRow(
                        color: nil,
                        title: "Free space",
                        detail: "\(Format.tokens(breakdown.freeTokens)) · \(percentText(100 - breakdown.usedPercent))"
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func percentText(_ value: Double) -> String {
        if value > 0, value < 0.1 { return "<0.1%" }
        return String(format: value < 10 ? "%.1f%%" : "%.0f%%", value)
    }

    private func legendRow(color: Color?, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color ?? Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.gray.opacity(color == nil ? 0.5 : 0), lineWidth: 1))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
        }
    }
}
