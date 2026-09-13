import SwiftUI
import AppKit

/// Design tokens — the only place numeric paddings, corner radii, type sizes,
/// and custom colors live in the app. Reach for these instead of hardcoding
/// literal numbers in views; see `AGENTS.md` for the rationale.
///
/// The palette and type scale mirror the web workspace theme
/// (`priv/static/styles/runner-theme.css`) so the Mac app and the web app
/// read as one product.
enum Tokens {
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
        static let page: CGFloat = 40
    }

    enum CornerRadius {
        static let hairline: CGFloat = 1
        static let checkbox: CGFloat = 3
        static let badge: CGFloat = 4
        static let control: CGFloat = 6
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
    }

    enum IconSize {
        static let providerMark: CGFloat = 15
        static let inline: CGFloat = 16
        static let regular: CGFloat = 20
        static let prominent: CGFloat = 28
        static let brandMark: CGFloat = 32
        static let large: CGFloat = 56
    }

    enum Stroke {
        static let hairline: CGFloat = 0.5
        static let control: CGFloat = 1
        static let activeBar: CGFloat = 2
    }

    enum Layout {
        static let sidebarWidth: CGFloat = 224
        static let sidebarTopInset: CGFloat = 64
        static let sidebarHorizontalInset: CGFloat = 14
        static let navRowMinHeight: CGFloat = 36
        static let avatarSize: CGFloat = 28
        static let statusDotSize: CGFloat = 5
        static let pageTopInset: CGFloat = 28
        static let pageMaxWidth: CGFloat = 1320
        static let controlHeight: CGFloat = 34
        static let searchFieldMaxWidth: CGFloat = 340
        static let checkboxSize: CGFloat = 14
        static let taskCheckboxColumn: CGFloat = 40
        static let taskSourceColumn: CGFloat = 250
        static let taskDueColumn: CGFloat = 100
        static let taskActionColumn: CGFloat = 96
        static let windowMinWidth: CGFloat = 960
        static let windowMinHeight: CGFloat = 600
        static let windowDefaultWidth: CGFloat = 1240
        static let windowDefaultHeight: CGFloat = 820
        static let onboardingMaxWidth: CGFloat = 480
        static let todoInspectorMinWidth: CGFloat = 280
        static let todoInspectorIdealWidth: CGFloat = 360
        static let todoInspectorMaxWidth: CGFloat = 480
        static let todoEditorWidth: CGFloat = 480
        static let shortcutHelpMinWidth: CGFloat = 420
        static let shortcutHelpMinHeight: CGFloat = 360
    }

    /// The web workspace type scale: 13px body, 12px small, 11px captions,
    /// 25px page titles. Declared here so views never spell out sizes.
    enum Typography {
        static let pageTitle = Font.system(size: 25, weight: .medium)
        static let pageTitleTracking: CGFloat = -0.8
        static let titleLineSpacing: CGFloat = 4
        static let brand = Font.system(size: 16, weight: .semibold)
        static let brandTracking: CGFloat = -0.4
        static let brandMark = Font.custom("Georgia", size: 26)
        static let brandMarkLarge = Font.custom("Georgia", size: 44)
        static let body = Font.system(size: 13)
        static let bodyMedium = Font.system(size: 13, weight: .medium)
        static let bodySemibold = Font.system(size: 13, weight: .semibold)
        static let small = Font.system(size: 12)
        static let smallMedium = Font.system(size: 12, weight: .medium)
        static let caption = Font.system(size: 11)
        static let captionMedium = Font.system(size: 11, weight: .medium)
        static let micro = Font.system(size: 10)
        static let navIcon = Font.system(size: 14, weight: .medium)
        static let checkmark = Font.system(size: 9, weight: .bold)
    }

    /// Runner workspace palette. Every color resolves per appearance so
    /// the app follows the Appearance setting (System, Light, Dark).
    enum Palette {
        static let background = Shade(light: 0xFCFCFA, dark: 0x21201D).color
        static let foreground = Shade(light: 0x252116, dark: 0xF7F7F5).color
        static let accent = Shade(light: 0xA86448, dark: 0xC88D6F).color
        static let selectedBar = Shade(light: 0xBF7743, dark: 0xBF7743).color
        static let caution = Shade(light: 0xD97706, dark: 0xFBBF24).color
        static let success = Shade(light: 0x16A34A, dark: 0x22C55E).color
        static let destructive = Shade(light: 0xDC2626, dark: 0xEF4444).color
        static let info = Shade(light: 0x2563EB, dark: 0x3B82F6).color
        static let indigo = Shade(light: 0x4F46E5, dark: 0x818CF8).color
        static let statusOnline = Shade(light: 0x79957B, dark: 0x79957B).color
        static let statusOffline = Shade(light: 0xD49D54, dark: 0xD49D54).color

        static let mutedForeground = foregroundShade.mixed(into: backgroundShade, 0.5).color
        static let foreground3 = foregroundShade.mixed(into: backgroundShade, 0.03).color
        static let foreground5 = foregroundShade.mixed(into: backgroundShade, 0.05).color
        static let foreground10 = foregroundShade.mixed(into: backgroundShade, 0.1).color
        static let foreground80 = foregroundShade.mixed(into: backgroundShade, 0.8).color
        static let selected = accentShade.mixed(into: backgroundShade, 0.09).color
        static let border = foregroundShade.withAlpha(0.1).color
        static let ring = foregroundShade.withAlpha(0.25).color
        static let surfaceRaised = Shade(light: 0xFFFFFF, dark: 0xFFFFFF).mixed(into: backgroundShade, 0.06).color

        static let cautionText = cautionShade.mixed(into: foregroundShade, 0.5).color
        static let destructiveText = destructiveShade.mixed(into: foregroundShade, 0.5).color

        private static let backgroundShade = Shade(light: 0xFCFCFA, dark: 0x21201D)
        private static let foregroundShade = Shade(light: 0x252116, dark: 0xF7F7F5)
        private static let accentShade = Shade(light: 0xA86448, dark: 0xC88D6F)
        private static let cautionShade = Shade(light: 0xD97706, dark: 0xFBBF24)
        private static let destructiveShade = Shade(light: 0xDC2626, dark: 0xEF4444)

        /// Catalyst badge recipe: a 15% fill of the hue and text mixed
        /// toward the foreground so it stays legible on both appearances.
        static func badgeFill(_ hue: Shade) -> Color { hue.withAlpha(0.15).color }
        static func badgeText(_ hue: Shade) -> Color { hue.mixed(into: foregroundShade, 0.62).color }
        static let badgeNeutralFill = foregroundShade.withAlpha(0.08).color
        static let badgeNeutralText = foregroundShade.mixed(into: backgroundShade, 0.72).color

        static let hueIndigo = Shade(light: 0x4F46E5, dark: 0x818CF8)
        static let hueRed = Shade(light: 0xDC2626, dark: 0xEF4444)
        static let hueAmber = Shade(light: 0xD97706, dark: 0xFBBF24)
        static let hueBlue = Shade(light: 0x2563EB, dark: 0x3B82F6)
        static let hueEmerald = Shade(light: 0x16A34A, dark: 0x22C55E)
    }
}

/// A light/dark color pair expressed in sRGB so mixes stay deterministic
/// and match the CSS `color-mix(in srgb, …)` recipes the web theme uses.
struct Shade: Sendable {
    let light: RGBA
    let dark: RGBA

    init(light: UInt32, dark: UInt32) {
        self.light = RGBA(hex: light)
        self.dark = RGBA(hex: dark)
    }

    init(light: RGBA, dark: RGBA) {
        self.light = light
        self.dark = dark
    }

    /// Blends `fraction` of this shade into `base` (like `color-mix`).
    func mixed(into base: Shade, _ fraction: Double) -> Shade {
        Shade(light: light.mixed(into: base.light, fraction), dark: dark.mixed(into: base.dark, fraction))
    }

    func withAlpha(_ alpha: Double) -> Shade {
        Shade(light: light.withAlpha(alpha), dark: dark.withAlpha(alpha))
    }

    var color: Color {
        let lightColor = light.nsColor
        let darkColor = dark.nsColor
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        })
    }
}

struct RGBA: Sendable {
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

    func mixed(into base: RGBA, _ fraction: Double) -> RGBA {
        let keep = 1 - fraction
        return RGBA(
            red: base.red * keep + red * fraction,
            green: base.green * keep + green * fraction,
            blue: base.blue * keep + blue * fraction,
            alpha: base.alpha * keep + alpha * fraction
        )
    }

    func withAlpha(_ value: Double) -> RGBA {
        RGBA(red: red, green: green, blue: blue, alpha: value)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// Status semantics — always paired with an SF Symbol; the color
/// vocabulary is small on purpose.
enum StatusTone: Equatable {
    case neutral
    case good
    case attention
    case error
    case muted

    var color: Color {
        switch self {
        case .neutral: return Tokens.Palette.accent
        case .good: return Tokens.Palette.success
        case .attention: return Tokens.Palette.caution
        case .error: return Tokens.Palette.destructive
        case .muted: return Tokens.Palette.mutedForeground
        }
    }
}
