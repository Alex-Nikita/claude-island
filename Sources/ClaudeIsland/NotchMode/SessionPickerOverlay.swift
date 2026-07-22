import SwiftUI

// Custom dropdown card: each session with its live state — pulsing status
// dot, project folder, context fill, and state word — things a native
// NSMenu can't render.
struct SessionPickerOverlay: View {
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool
    let topInset: CGFloat

    // The card drops from the session-header title. The overlay is
    // positioned from the panel's top-left rather than anchored to the
    // button, so these offsets mirror the header's fixed geometry (wing
    // strip height + header rows / tab rail width). Change the header
    // layout and these move with it.
    static let topOffset: CGFloat = 66
    static let leadingOffset: CGFloat = 215

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Invisible catch layer: clicking anywhere else closes.
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { isPresented = false }
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(appState.sessions.enumerated()), id: \.element.id) { index, session in
                            row(session, index: index)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 200)
            }
            .frame(width: 330)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.pickerBackground))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
            .padding(.top, topInset + Self.topOffset)
            .padding(.leading, Self.leadingOffset)
        }
    }

    private func row(_ session: SessionInfo, index: Int) -> some View {
        let isCurrent = index == appState.selectedSessionIndex
        return Button {
            appState.selectedSessionIndex = index
            isPresented = false
        } label: {
            HStack(spacing: 8) {
                StatusDot(
                    color: session.statusColor(appState.colors),
                    pulsing: session.isActivelyWorking || session.needsAttention,
                    symbol: session.statusSymbol(symbolsEnabled: appState.symbolsEnabled)
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(URL(fileURLWithPath: session.cwd).lastPathComponent)
                        .font(.system(size: 9))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let ctx = session.contextPercent {
                    Text("\(ctx)%")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundColor(session.contextIsHigh ? appState.colors.waiting : .gray)
                }
                Text(session.stateWord)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(session.stateColor(appState.colors))
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.claudeOrange)
                    .opacity(isCurrent ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isCurrent ? Color.white.opacity(0.08) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
