/// Source marks identify the application that supplied the task evidence.
import SwiftUI
import AppKit

struct TodoProviderMark: View {
    let provider: String
    var size: CGFloat = Tokens.Spacing.large

    var body: some View {
        if let image = sourceImage {
            Image(nsImage: image).resizable().scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: fallbackSymbol)
                .font(size <= Tokens.IconSize.inline ? Tokens.Typography.small : Tokens.Typography.body)
                .frame(width: size, height: size)
                .foregroundStyle(Tokens.Palette.mutedForeground)
                .accessibilityHidden(true)
        }
    }

    /// Assistant-generated sources (morning briefing, reviews) and manual
    /// entries use the same sparkle the web shows; calendar keeps its glyph.
    private var fallbackSymbol: String {
        switch provider {
        case "calendar", "google_calendar", "calendar_local": return "calendar"
        default: return "sparkles"
        }
    }

    private var sourceImage: NSImage? {
        let name: String
        switch provider {
        case "browser": name = "Chrome"
        case "gmail", "gmail_thread": name = "Gmail"
        case "slack": name = "Slack"
        case "imessage", "messages", "local_patterns", "desktop": name = "Messages"
        default: return nil
        }
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "TodoProvider" + name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}
