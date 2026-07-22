import SwiftUI

// A comet — bright head, fading tail — that traces one lap of the island's
// border (top edge, down the right side, across the bottom, back up the
// left) each time `trigger` increments (response finished).
struct BorderTrail: View {
    var trigger: Int = 0
    var color: Color
    var bottomRadius: CGFloat

    @State private var phase: CGFloat = 0
    @State private var active = false
    @State private var generation = 0

    var body: some View {
        ZStack {
            segment(tail: 0.16, width: 3.5, opacity: 0.28, blur: 2.5)
            segment(tail: 0.09, width: 2.2, opacity: 0.65, blur: 0.8)
            segment(tail: 0.025, width: 2.2, opacity: 1.0, blur: 0)
        }
        .shadow(color: color.opacity(0.8), radius: 3)
        .opacity(active ? 1 : 0)
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in fireOnce() }
    }

    private func segment(tail: CGFloat, width: CGFloat, opacity: Double, blur: CGFloat) -> some View {
        NotchOutline(bottomRadius: bottomRadius)
            .trim(from: max(0, phase - tail), to: min(1, phase))
            .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
            .opacity(opacity)
            .blur(radius: blur)
    }

    private func fireOnce() {
        generation += 1
        let gen = generation
        resetPhase()
        active = true
        withAnimation(.easeInOut(duration: 1.2)) {
            phase = 1.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            if gen == generation {
                active = false
            }
        }
    }

    private func resetPhase() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { phase = 0 }
    }
}
