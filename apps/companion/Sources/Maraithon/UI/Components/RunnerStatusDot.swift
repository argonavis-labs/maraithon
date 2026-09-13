import SwiftUI

/// 8pt status dot for source detail pages. A `pulsing` dot fades in and
/// out to signal an in-flight check unless Reduce Motion is on.
struct RunnerStatusDot: View {
    let color: Color
    var pulsing = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: Tokens.SourcesLayout.statusDotSize, height: Tokens.SourcesLayout.statusDotSize)
            .opacity(dimmed ? 0.35 : 1)
            .onAppear(perform: startPulse)
            .onChange(of: pulsing) { _, _ in startPulse() }
            .accessibilityHidden(true)
    }

    private func startPulse() {
        guard pulsing, !reduceMotion else {
            withAnimation(.easeOut(duration: 0.12)) { dimmed = false }
            return
        }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            dimmed = true
        }
    }
}
