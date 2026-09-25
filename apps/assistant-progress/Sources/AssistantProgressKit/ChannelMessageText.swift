/// Renders Slack's native inline formatting while leaving email and Messages
/// as their exact plain text. Rendering never changes the outgoing payload.
import SwiftUI

public struct ChannelMessageText: View {
    let text: String
    let provider: String
    public init(_ text: String, provider: String) { self.text = text; self.provider = provider }

    public var body: some View {
        Group {
            if provider == "slack" {
                Text((try? AttributedString(markdown: slackMarkdown,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
            } else {
                Text(text)
            }
        }.textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }

    private var slackMarkdown: String {
        text
            .replacingOccurrences(of: #"<(https?://[^>|]+)\|([^>]+)>"#, with: "[$2]($1)", options: .regularExpression)
            .replacingOccurrences(of: #"<(https?://[^>]+)>"#, with: "<$1>", options: .regularExpression)
            .replacingOccurrences(of: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#, with: "**$1**", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
