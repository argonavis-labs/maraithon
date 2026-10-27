import SwiftUI

/// Workspace buttons: ink primary, hairline secondary, quiet plain. Touch
/// targets stay at least 44pt unless `compact`.
struct RunnerButtonStyle: ButtonStyle {
    enum Variant { case primary, secondary, plain, destructive }

    let variant: Variant
    var compact = false
    var fullWidth = false

    init(_ variant: Variant, compact: Bool = false, fullWidth: Bool = false) {
        self.variant = variant
        self.compact = compact
        self.fullWidth = fullWidth
    }

    func makeBody(configuration: Configuration) -> some View {
        RunnerButtonBody(configuration: configuration, variant: variant, compact: compact, fullWidth: fullWidth)
    }
}

private struct RunnerButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let variant: RunnerButtonStyle.Variant
    let compact: Bool
    let fullWidth: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .lineLimit(1)
            .font(variant == .plain ? Runner.Typography.smallMedium : Runner.Typography.bodyMedium)
            .foregroundStyle(foreground)
            .padding(.horizontal, variant == .plain ? Runner.Spacing.xsmall : Runner.Spacing.medium)
            .frame(minHeight: compact ? Runner.Layout.compactControlHeight : Runner.Layout.controlHeight)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(background, in: RoundedRectangle(cornerRadius: Runner.Radius.control, style: .continuous))
            .overlay {
                if variant == .secondary || variant == .destructive {
                    RoundedRectangle(cornerRadius: Runner.Radius.control, style: .continuous)
                        .stroke(Runner.Palette.border, lineWidth: Runner.Stroke.hairline)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: Runner.Radius.control, style: .continuous))
    }

    private var foreground: Color {
        switch variant {
        case .primary: return Runner.Palette.background
        case .secondary: return Runner.Palette.foreground
        case .plain: return Runner.Palette.mutedForeground
        case .destructive: return Runner.Palette.destructiveText
        }
    }

    private var background: Color {
        switch variant {
        case .primary: return Runner.Palette.foreground
        case .secondary, .destructive: return configuration.isPressed ? Runner.Palette.foreground3 : .clear
        case .plain: return .clear
        }
    }
}
