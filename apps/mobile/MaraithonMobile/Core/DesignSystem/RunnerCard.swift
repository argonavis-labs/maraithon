import SwiftUI

/// Hairline card on the workspace ground. Rows inside separate with
/// `RunnerHairline`; use `.runnerCardRow()` for standard row padding.
struct RunnerCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background(Runner.Palette.background)
        .clipShape(RoundedRectangle(cornerRadius: Runner.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Runner.Radius.card, style: .continuous)
                .stroke(Runner.Palette.border, lineWidth: Runner.Stroke.hairline)
        }
    }
}

struct RunnerHairline: View {
    var body: some View {
        Rectangle()
            .fill(Runner.Palette.border)
            .frame(height: Runner.Stroke.hairline)
    }
}

/// Uppercase caption heading above a section.
struct RunnerSectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(Runner.Typography.captionMedium)
            .tracking(0.6)
            .foregroundStyle(Runner.Palette.mutedForeground)
            .accessibilityAddTraits(.isHeader)
    }
}

struct RunnerKeyValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: Runner.Spacing.small) {
            Text(label)
                .font(Runner.Typography.small)
                .foregroundStyle(Runner.Palette.mutedForeground)
            Spacer(minLength: Runner.Spacing.small)
            Text(value)
                .font(Runner.Typography.small.monospacedDigit())
                .foregroundStyle(Runner.Palette.foreground)
                .multilineTextAlignment(.trailing)
        }
        .runnerCardRow()
    }
}

struct RunnerStatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: Runner.Layout.statusDot, height: Runner.Layout.statusDot)
            .accessibilityHidden(true)
    }
}

private struct RunnerCardRowChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Runner.Spacing.medium)
            .padding(.vertical, Runner.Spacing.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    func runnerCardRow() -> some View { modifier(RunnerCardRowChrome()) }
}
