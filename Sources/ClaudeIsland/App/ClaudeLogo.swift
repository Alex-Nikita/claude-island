import SwiftUI

// Claude asterisk / starburst mark, drawn as rounded rays.
struct ClaudeLogo: View {
    var color: Color = .claudeOrange

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let rayLength = size * 0.42
            let rayWidth = size * 0.16
            ZStack {
                ForEach(0..<8, id: \.self) { i in
                    Capsule(style: .continuous)
                        .fill(color)
                        .frame(width: rayWidth, height: rayLength)
                        .offset(y: -rayLength / 2)
                        .rotationEffect(.degrees(Double(i) * 45))
                        .position(center)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Claude")
    }
}

// Spins continuously while `active` (a session is generating), eases back
// to rest when idle.
struct SpinningClaudeLogo: View {
    var active: Bool
    var color: Color = .claudeOrange

    @State private var spinning = false

    var body: some View {
        ClaudeLogo(color: color)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(
                spinning
                    ? .linear(duration: 2.4).repeatForever(autoreverses: false)
                    : .easeOut(duration: 0.4),
                value: spinning
            )
            .onAppear { spinning = active }
            .onChange(of: active) { _, isActive in spinning = isActive }
    }
}

// Spin while working; a Dock-style double bounce each time `pulseTrigger`
// increments (job complete); continuous periodic bouncing while `attention`
// (a prompt is waiting for the user).
struct ClaudeLogoBadge: View {
    var active: Bool
    var pulseTrigger: Int
    var attention: Bool = false
    var color: Color = .claudeOrange

    @State private var lift: CGFloat = 0
    @State private var attentionGeneration = 0

    var body: some View {
        SpinningClaudeLogo(active: active, color: color)
            .offset(y: lift)
            .onChange(of: pulseTrigger) { _, _ in bounce(height: 7, times: 2) }
            .onChange(of: attention) { _, isOn in isOn ? startAttentionBounce() : stopAttentionBounce() }
            .onAppear { if attention { startAttentionBounce() } }
    }

    private func startAttentionBounce() {
        attentionGeneration += 1
        let generation = attentionGeneration
        func hop() {
            guard generation == attentionGeneration else { return }
            bounce(height: 7, times: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { hop() }
        }
        hop()
    }

    private func stopAttentionBounce() {
        attentionGeneration += 1
    }

    private func bounce(height: CGFloat, times: Int) {
        guard times > 0 else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            lift = -height
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.interpolatingSpring(stiffness: 450, damping: 12)) {
                lift = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                bounce(height: height * 0.6, times: times - 1)
            }
        }
    }
}
