import SwiftUI

/// Catalyst-style badge shared by the task list, sidebar, and detail views.
/// Invariant: tones map 1:1 to the web `<.badge color=…>` vocabulary so a
/// status reads the same color on every surface.
struct RunnerBadge: View {
    enum Tone: Equatable {
        case zinc
        case indigo
        case red
        case amber
        case blue
        case emerald

        var fill: Color {
            switch self {
            case .zinc: return Tokens.Palette.badgeNeutralFill
            case .indigo: return Tokens.Palette.badgeFill(Tokens.Palette.hueIndigo)
            case .red: return Tokens.Palette.badgeFill(Tokens.Palette.hueRed)
            case .amber: return Tokens.Palette.badgeFill(Tokens.Palette.hueAmber)
            case .blue: return Tokens.Palette.badgeFill(Tokens.Palette.hueBlue)
            case .emerald: return Tokens.Palette.badgeFill(Tokens.Palette.hueEmerald)
            }
        }

        var text: Color {
            switch self {
            case .zinc: return Tokens.Palette.badgeNeutralText
            case .indigo: return Tokens.Palette.badgeText(Tokens.Palette.hueIndigo)
            case .red: return Tokens.Palette.badgeText(Tokens.Palette.hueRed)
            case .amber: return Tokens.Palette.badgeText(Tokens.Palette.hueAmber)
            case .blue: return Tokens.Palette.badgeText(Tokens.Palette.hueBlue)
            case .emerald: return Tokens.Palette.badgeText(Tokens.Palette.hueEmerald)
            }
        }
    }

    let text: String
    var tone: Tone = .zinc
    /// Offer pills in the Source column wrap to two lines; status chips stay on one.
    var wraps = false

    var body: some View {
        Text(text)
            .font(Tokens.Typography.smallMedium)
            .foregroundStyle(tone.text)
            .lineLimit(wraps ? 3 : 1)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: wraps)
            .padding(.horizontal, Tokens.Spacing.compact)
            .padding(.vertical, Tokens.Spacing.xxsmall)
            .background(tone.fill, in: RoundedRectangle(cornerRadius: Tokens.CornerRadius.badge))
    }
}
