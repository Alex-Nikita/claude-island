import SwiftUI

struct CollapsedNotchView: View {
    @ObservedObject var appState: AppState
    let notchWidth: CGFloat
    let expand: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                ClaudeLogoBadge(
                    active: appState.isAnySessionBusy,
                    pulseTrigger: appState.completionPulseCount,
                    attention: appState.needsUserAttention
                )
                .frame(width: 16, height: 16)
            }
            // The panel's width is computed from this same constant — the
            // wings and the frame must agree.
            .frame(width: NotchModeController.wingWidth)
            .frame(maxHeight: .infinity)

            Spacer()
                .frame(width: notchWidth)

            Text(appState.percentLeftText)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundColor(.white)
                .frame(width: NotchModeController.wingWidth)
                .frame(maxHeight: .infinity)
                .help(appState.percentDescription)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NotchShape(bottomRadius: 10).fill(Color.black))
        .overlay(BorderTrail(trigger: appState.completionPulseCount, color: .claudeOrange, bottomRadius: 10))
        .overlay(AttentionBorder(active: appState.needsUserAttention, bottomRadius: 10))
        // The bar covers this strip of the menu bar anyway, so let every
        // point of it expand the island — not just the logo wing.
        .contentShape(Rectangle())
        .onTapGesture { expand() }
        // Top stays flush with the screen edge; sides and bottom keep slack
        // so trail strokes and glow aren't clipped by the panel boundary.
        .padding(.horizontal, NotchModeController.strokeSlack / 2)
        .padding(.bottom, NotchModeController.strokeSlack)
    }
}
