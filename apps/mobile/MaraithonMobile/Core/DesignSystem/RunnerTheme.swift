import SwiftUI
import UIKit

/// Runner workspace theme shared with the web and Mac apps: warm off-white
/// ground, ink text, terracotta accent, hairline borders. Every color resolves
/// per appearance so light and dark follow the system setting.
enum Runner {
    enum Palette {
        static let background = RunnerShade(light: 0xFCFCFA, dark: 0x21201D).color
        static let foreground = RunnerShade(light: 0x252116, dark: 0xF7F7F5).color
        static let accent = RunnerShade(light: 0xA86448, dark: 0xC88D6F).color
        static let selectedBar = RunnerShade(light: 0xBF7743, dark: 0xBF7743).color
        static let caution = RunnerShade(light: 0xD97706, dark: 0xFBBF24).color
        static let success = RunnerShade(light: 0x16A34A, dark: 0x22C55E).color
        static let destructive = RunnerShade(light: 0xDC2626, dark: 0xEF4444).color
        static let info = RunnerShade(light: 0x2563EB, dark: 0x3B82F6).color
        static let indigo = RunnerShade(light: 0x4F46E5, dark: 0x818CF8).color

        static let mutedForeground = foregroundShade.mixed(into: backgroundShade, 0.5).color
        static let foreground3 = foregroundShade.mixed(into: backgroundShade, 0.03).color
        static let foreground5 = foregroundShade.mixed(into: backgroundShade, 0.05).color
        static let foreground10 = foregroundShade.mixed(into: backgroundShade, 0.1).color
        static let foreground80 = foregroundShade.mixed(into: backgroundShade, 0.8).color
        static let selected = accentShade.mixed(into: backgroundShade, 0.09).color
        static let border = foregroundShade.withAlpha(0.1).color
        static let ring = foregroundShade.withAlpha(0.25).color
        static let surfaceRaised = RunnerShade(light: 0xFFFFFF, dark: 0xFFFFFF).mixed(into: backgroundShade, 0.06).color

        static let cautionText = cautionShade.mixed(into: foregroundShade, 0.5).color
        static let destructiveText = destructiveShade.mixed(into: foregroundShade, 0.5).color
        static let successText = successShade.mixed(into: foregroundShade, 0.5).color
        static let infoText = infoShade.mixed(into: foregroundShade, 0.5).color

        /// Catalyst badge recipe: 15% fill of the hue, text mixed toward ink.
        static func badgeFill(_ hue: RunnerShade) -> Color { hue.withAlpha(0.15).color }
        static func badgeText(_ hue: RunnerShade) -> Color { hue.mixed(into: foregroundShade, 0.62).color }
        static let badgeNeutralFill = foregroundShade.withAlpha(0.08).color
        static let badgeNeutralText = foregroundShade.mixed(into: backgroundShade, 0.72).color

        static let hueIndigo = RunnerShade(light: 0x4F46E5, dark: 0x818CF8)
        static let hueRed = RunnerShade(light: 0xDC2626, dark: 0xEF4444)
        static let hueAmber = RunnerShade(light: 0xD97706, dark: 0xFBBF24)
        static let hueBlue = RunnerShade(light: 0x2563EB, dark: 0x3B82F6)
        static let hueEmerald = RunnerShade(light: 0x16A34A, dark: 0x22C55E)

        static let backgroundShade = RunnerShade(light: 0xFCFCFA, dark: 0x21201D)
        static let foregroundShade = RunnerShade(light: 0x252116, dark: 0xF7F7F5)
        static let accentShade = RunnerShade(light: 0xA86448, dark: 0xC88D6F)
        private static let cautionShade = RunnerShade(light: 0xD97706, dark: 0xFBBF24)
        private static let destructiveShade = RunnerShade(light: 0xDC2626, dark: 0xEF4444)
        private static let successShade = RunnerShade(light: 0x16A34A, dark: 0x22C55E)
        private static let infoShade = RunnerShade(light: 0x2563EB, dark: 0x3B82F6)
    }

    /// Phone type scale (the web theme's under-768px sizes), scaled with
    /// Dynamic Type through `relativeTo`.
    enum Typography {
        static let pageTitle = Font.system(size: 26, weight: .semibold, design: .default)
        static let pageTitleTracking: CGFloat = -0.6
        static let sectionTitle = Font.system(size: 18, weight: .semibold)
        static let brandMark = Font.custom("Georgia", size: 24)
        static let body = Font.system(size: 16, weight: .regular)
        static let bodyMedium = Font.system(size: 16, weight: .medium)
        static let bodySemibold = Font.system(size: 16, weight: .semibold)
        static let small = Font.system(size: 14, weight: .regular)
        static let smallMedium = Font.system(size: 14, weight: .medium)
        static let caption = Font.system(size: 12, weight: .regular)
        static let captionMedium = Font.system(size: 12, weight: .medium)
        static let micro = Font.system(size: 11, weight: .regular)
        static let icon = Font.system(size: 16, weight: .medium)
        static let checkmark = Font.system(size: 11, weight: .bold)
    }

    enum Spacing {
        static let xxsmall: CGFloat = 2
        static let xsmall: CGFloat = 4
        static let compact: CGFloat = 6
        static let small: CGFloat = 8
        static let snug: CGFloat = 10
        static let tight: CGFloat = 12
        static let medium: CGFloat = 16
        static let roomy: CGFloat = 20
        static let large: CGFloat = 24
        static let xlarge: CGFloat = 32
    }

    enum Radius {
        static let checkbox: CGFloat = 5
        static let badge: CGFloat = 6
        static let control: CGFloat = 8
        static let card: CGFloat = 12
        static let mark: CGFloat = 8
    }

    enum Stroke {
        static let hairline: CGFloat = 0.5
        static let control: CGFloat = 1
        static let activeBar: CGFloat = 2
    }

    enum Layout {
        static let controlHeight: CGFloat = 44
        static let compactControlHeight: CGFloat = 36
        static let checkboxSize: CGFloat = 22
        static let avatarSize: CGFloat = 36
        static let statusDot: CGFloat = 8
        static let providerMark: CGFloat = 18
        static let pageInset: CGFloat = 16
    }
}

/// A light/dark color pair in sRGB so mixes match the CSS `color-mix`
/// recipes the web theme uses.
struct RunnerShade: Sendable {
    let light: RunnerRGBA
    let dark: RunnerRGBA

    init(light: UInt32, dark: UInt32) {
        self.light = RunnerRGBA(hex: light)
        self.dark = RunnerRGBA(hex: dark)
    }

    init(light: RunnerRGBA, dark: RunnerRGBA) {
        self.light = light
        self.dark = dark
    }

    func mixed(into base: RunnerShade, _ fraction: Double) -> RunnerShade {
        RunnerShade(light: light.mixed(into: base.light, fraction), dark: dark.mixed(into: base.dark, fraction))
    }

    func withAlpha(_ alpha: Double) -> RunnerShade {
        RunnerShade(light: light.withAlpha(alpha), dark: dark.withAlpha(alpha))
    }

    var color: Color {
        let lightColor = light.uiColor
        let darkColor = dark.uiColor
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? darkColor : lightColor
        })
    }
}

struct RunnerRGBA: Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    func mixed(into base: RunnerRGBA, _ fraction: Double) -> RunnerRGBA {
        let keep = 1 - fraction
        return RunnerRGBA(
            red: base.red * keep + red * fraction,
            green: base.green * keep + green * fraction,
            blue: base.blue * keep + blue * fraction,
            alpha: base.alpha * keep + alpha * fraction
        )
    }

    func withAlpha(_ value: Double) -> RunnerRGBA {
        RunnerRGBA(red: red, green: green, blue: blue, alpha: value)
    }

    var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}
