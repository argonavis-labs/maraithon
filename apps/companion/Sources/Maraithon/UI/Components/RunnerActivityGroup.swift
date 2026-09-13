import SwiftUI

/// The steps behind one assistant turn, folded into a single muted line:
/// chevron, a preview sentence, and a count chip. Closed by default so the
/// reply reads as prose; expanding lists each step with its outcome.
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

    @State private var expanded: Bool
    @State private var hovering = false

    /// A settled turn folds its steps; a live turn opens them so each call
    /// shows up as it happens.
    init(preview: String, steps: [Step], expanded: Bool = false) {
        self.preview = preview
        self.steps = steps
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.compact) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: Tokens.Spacing.compact) {
                    Image(systemName: "chevron.right")
                        .font(Tokens.Typography.caption)
                        .rotationEffect(expanded ? .degrees(90) : .zero)
                        .accessibilityHidden(true)
                    Text(preview)
                        .font(Tokens.Typography.small)
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
                VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
                    ForEach(steps) { step in row(step) }
                }
                .padding(.leading, Tokens.Spacing.medium)
                .transition(.opacity)
            }
        }
    }

    private func row(_ step: Step) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.small) {
            glyph(for: step.status)
                .frame(width: Tokens.SourcesLayout.rowIconColumnWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxsmall) {
                Text(step.label)
                    .font(Tokens.Typography.small)
                    .foregroundStyle(Tokens.Palette.foreground80)
                if let summary = step.summary, !summary.isEmpty {
                    Text(summary)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.mutedForeground)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let detail = step.detail, !detail.isEmpty {
                    Text(detail)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
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
