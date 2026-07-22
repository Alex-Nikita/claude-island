import SwiftUI

// Solid glowing border shown while a session is blocked on the user —
// permanently lit with a slow breathing pulse until the prompt is answered.
struct AttentionBorder: View {
    var active: Bool
    var bottomRadius: CGFloat

    @State private var breathing = false

    var body: some View {
        ZStack {
            NotchOutline(bottomRadius: bottomRadius)
                .stroke(Color.attentionBeige, lineWidth: 2.5)
                .blur(radius: 2)
                .opacity(0.7)
            NotchOutline(bottomRadius: bottomRadius)
                .stroke(Color.attentionBeige.opacity(0.95), lineWidth: 1.5)
        }
        .shadow(color: Color.attentionBeige.opacity(0.8), radius: 4)
        .opacity(breathing ? 1.0 : 0.55)
        .opacity(active ? 1 : 0)
        .animation(.easeOut(duration: 0.4), value: active)
        .allowsHitTesting(false)
        .onChange(of: active) { _, isOn in isOn ? startBreathing() : stopBreathing() }
        .onAppear { if active { startBreathing() } }
    }

    private func startBreathing() {
        stopBreathing()
        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
            breathing = true
        }
    }

    private func stopBreathing() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { breathing = false }
    }
}
