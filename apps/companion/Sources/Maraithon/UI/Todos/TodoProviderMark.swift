/// Source marks identify the application that supplied the task evidence.
import SwiftUI
import AppKit

struct TodoProviderMark: View {
    let provider: String
    var body: some View {
        if let image = sourceImage {
            Image(nsImage: image).resizable().scaledToFit()
                .frame(width: Tokens.Spacing.large, height: Tokens.Spacing.large)
                .accessibilityHidden(true)
        } else {
            Image(systemName: provider == "calendar" ? "calendar" : "globe")
                .frame(width: Tokens.Spacing.large, height: Tokens.Spacing.large)
                .foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }
    private var sourceImage: NSImage? {
        let name: String
        switch provider {
        case "browser": name = "Chrome"
        case "gmail": name = "Gmail"
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
