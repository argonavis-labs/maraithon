import SwiftUI

/// Catalyst-style badge with the same tone vocabulary as the web and Mac apps.
struct RunnerBadge: View {
    enum Tone: Equatable {
        case zinc, indigo, red, amber, blue, emerald

        var fill: Color {
            switch self {
            case .zinc: return Runner.Palette.badgeNeutralFill
            case .indigo: return Runner.Palette.badgeFill(Runner.Palette.hueIndigo)
            case .red: return Runner.Palette.badgeFill(Runner.Palette.hueRed)
            case .amber: return Runner.Palette.badgeFill(Runner.Palette.hueAmber)
            case .blue: return Runner.Palette.badgeFill(Runner.Palette.hueBlue)
            case .emerald: return Runner.Palette.badgeFill(Runner.Palette.hueEmerald)
            }
        }

        var text: Color {
            switch self {
            case .zinc: return Runner.Palette.badgeNeutralText
            case .indigo: return Runner.Palette.badgeText(Runner.Palette.hueIndigo)
            case .red: return Runner.Palette.badgeText(Runner.Palette.hueRed)
            case .amber: return Runner.Palette.badgeText(Runner.Palette.hueAmber)
            case .blue: return Runner.Palette.badgeText(Runner.Palette.hueBlue)
            case .emerald: return Runner.Palette.badgeText(Runner.Palette.hueEmerald)
            }
        }

        /// Maps the app's existing semantic tints onto badge tones.
        static func from(tint: Color) -> Tone {
            switch tint {
            case .red, .pink: return .red
            case .orange, .yellow: return .amber
            case .green, .mint, .teal: return .emerald
            case .blue, .cyan: return .blue
            case .indigo, .purple: return .indigo
            default: return .zinc
            }
        }
    }

    let text: String
    var tone: Tone = .zinc
    var wraps = false

    var body: some View {
        Text(text)
            .font(Runner.Typography.captionMedium)
            .foregroundStyle(tone.text)
            .lineLimit(wraps ? 3 : 1)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: wraps)
            .padding(.horizontal, Runner.Spacing.compact)
            .padding(.vertical, Runner.Spacing.xxsmall + 1)
            .background(tone.fill, in: RoundedRectangle(cornerRadius: Runner.Radius.badge, style: .continuous))
    }
}
