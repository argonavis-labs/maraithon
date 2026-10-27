import SwiftUI

/// The steps behind one assistant turn, folded into a single muted line:
/// chevron, a preview sentence, and a count chip. Closed by default so the
/// reply reads as prose. A live group is the working line itself: it opens,
/// pulses, and counts elapsed time, so nothing repeats beneath it.
struct RunnerActivityGroup: View {
    struct Step: Identifiable {
        let id: Int
        let label: String
        let status: String?
        let summary: String?
        let detail: String?
    }

    let preview: String
    let steps: [Step]
    let live: Bool
    let since: Date?

    @State private var expanded: Bool
    @State private var hovering = false

    /// A settled turn folds its steps; a live turn opens them so each call
    /// shows up as it happens.
    init(preview: String, steps: [Step], expanded: Bool = false, live: Bool = false, since: Date? = nil) {
        self.preview = preview
        self.steps = steps
        self.live = live
        self.since = since
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.compact) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: Tokens.Spacing.compact) {
                    if live {
                        RunnerStatusDot(color: Tokens.Palette.accent, pulsing: true)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(Tokens.Typography.caption)
                            .rotationEffect(expanded ? .degrees(90) : .zero)
                            .accessibilityHidden(true)
                    }
                    headerText
                        .font(Tokens.Typography.small)
                        .monospacedDigit()
                        .lineLimit(1)
                    Text("\(steps.count)")
                        .font(Tokens.Typography.captionMedium)
                        .monospacedDigit()
                        .padding(.horizontal, Tokens.Spacing.xsmall)
                        .frame(minWidth: Tokens.TodoLayout.activityCountMinWidth)
                        .background(Tokens.Palette.foreground5, in: RoundedRectangle(cornerRadius: Tokens.CornerRadius.badge))
                }
                .foregroundStyle(hovering || expanded ? Tokens.Palette.foreground80 : Tokens.Palette.mutedForeground)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel("\(steps.count) steps. \(preview)")
            .accessibilityHint(expanded ? "Collapses the steps" : "Shows each step")

            if expanded {
                VStack(alignment: .leading, spacing: Tokens.Spacing.compact) {
                    ForEach(steps) { step in row(step) }
                }
                .padding(.leading, Tokens.Spacing.medium)
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder private var headerText: some View {
        if live, let since {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(RunnerWorkingIndicator.text(label: preview, since: since, now: context.date))
            }
        } else {
            Text(preview)
        }
    }

    /// One line per step: the label as a muted prefix, then what it found.
    private func row(_ step: Step) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.small) {
            glyph(for: step.status)
                .frame(width: Tokens.SourcesLayout.rowIconColumnWidth, alignment: .leading)
            (Text(step.label + (outcome(step) == nil ? "" : " · ")).foregroundStyle(Tokens.Palette.mutedForeground)
                + Text(outcome(step) ?? "").foregroundStyle(Tokens.Palette.foreground80))
                .font(Tokens.Typography.small)
                .lineLimit(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func outcome(_ step: Step) -> String? {
        let text = [step.summary, step.detail].compactMap { $0 }.first { !$0.isEmpty }
        return text
    }

    @ViewBuilder
    private func glyph(for status: String?) -> some View {
        switch status {
        case "failed":
            Image(systemName: "exclamationmark.triangle")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.cautionText)
                .accessibilityLabel("Failed")
        case "running":
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Running")
        default:
            Image(systemName: "checkmark")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.mutedForeground)
                .accessibilityLabel("Done")
        }
    }
}
