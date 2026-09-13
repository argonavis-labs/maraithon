import SwiftUI

/// Liveness marker at the foot of a transcript: a pulsing accent dot and
/// "Working… 12s". It reads run status and start time only, never content,
/// so it cannot blink while streamed text or folded activity changes.
struct RunnerWorkingIndicator: View {
    var label = "Working…"
    var since: Date? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: Tokens.Spacing.small) {
                RunnerStatusDot(color: Tokens.Palette.accent, pulsing: true)
                Text(Self.text(label: label, since: since, now: context.date))
                    .font(Tokens.Typography.small)
                    .foregroundStyle(Tokens.Palette.mutedForeground)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        }
    }

    static func text(label: String, since: Date?, now: Date) -> String {
        guard let since else { return label }
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        let elapsed = seconds < 60 ? "\(seconds)s" : String(format: "%dm %02ds", seconds / 60, seconds % 60)
        return "\(label) \(elapsed)"
    }
}
