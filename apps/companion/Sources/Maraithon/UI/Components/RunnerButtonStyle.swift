import SwiftUI

/// Workspace button styles: a dark primary, a hairline secondary, and a
/// quiet text-only plain variant. Hover and pressed feedback match the web
/// (120ms color transitions, no shadows, 6pt radius).
struct RunnerButtonStyle: ButtonStyle {
    enum Variant {
        case primary
        case secondary
        case plain
    }

    let variant: Variant
    var compact = false

    init(_ variant: Variant, compact: Bool = false) {
        self.variant = variant
        self.compact = compact
    }

    func makeBody(configuration: Configuration) -> some View {
        RunnerButtonBody(configuration: configuration, variant: variant, compact: compact)
    }
}

private struct RunnerButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let variant: RunnerButtonStyle.Variant
    let compact: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(variant == .plain ? Tokens.Typography.small : Tokens.Typography.bodyMedium)
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(background, in: RoundedRectangle(cornerRadius: Tokens.CornerRadius.control))
            .overlay {
                if variant == .secondary {
                    RoundedRectangle(cornerRadius: Tokens.CornerRadius.control)
                        .stroke(Tokens.Palette.border, lineWidth: Tokens.Stroke.hairline)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: Tokens.CornerRadius.control))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var foreground: Color {
        switch variant {
        case .primary: return Tokens.Palette.background
        case .secondary: return hovering ? Tokens.Palette.foreground : Tokens.Palette.foreground80
        case .plain: return hovering ? Tokens.Palette.foreground : Tokens.Palette.mutedForeground
        }
    }

    private var background: Color {
        switch variant {
        case .primary: return Tokens.Palette.foreground.opacity(hovering ? 0.9 : 1)
        case .secondary: return hovering ? Tokens.Palette.foreground3 : .clear
        case .plain: return .clear
        }
    }

    private var horizontalPadding: CGFloat {
        switch variant {
        case .plain: return Tokens.Spacing.xsmall
        default: return compact ? Tokens.Spacing.snug : Tokens.Spacing.tight
        }
    }

    private var verticalPadding: CGFloat {
        switch variant {
        case .plain: return Tokens.Spacing.xxsmall
        default: return compact ? Tokens.Spacing.compact : Tokens.Spacing.small
        }
    }
}
