import SwiftUI

@MainActor
struct PillView: View {
    @ObservedObject var appState: AppState
    @State private var hovering = false

    private var isLow: Bool {
        appState.snapshot?.isLowBudget ?? false
    }

    var body: some View {
        Text(appState.percentLeftText)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(isLow ? appState.colors.low : Color.claudeOrange))
            .brightness(hovering ? 0.07 : 0)
            .onHover { hovering = $0 }
            .frame(height: 22)
            .help(appState.percentDescription)
            .accessibilityLabel(appState.percentDescription)
    }
}
