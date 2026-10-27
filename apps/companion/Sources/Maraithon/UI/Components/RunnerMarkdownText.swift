import SwiftUI

/// Assistant prose. Inline markdown (emphasis, links, code) renders; block
/// syntax stays as written so a numbered list keeps its lines. Falls back to
/// the raw text when parsing fails.
struct RunnerMarkdownText: View {
    let text: String

    var body: some View {
        Text(attributed)
            .font(Tokens.Typography.body)
            .foregroundStyle(Tokens.Palette.foreground)
            .lineSpacing(Tokens.TodoLayout.proseLineSpacing)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
