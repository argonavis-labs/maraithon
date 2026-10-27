import SwiftUI

struct ChatThreadRow: View {
    let thread: ChatThread

    private var latestMessage: ChatMessage? {
        // O(n) max instead of sorting the whole relationship for one element.
        thread.messages.max { $0.sentAt < $1.sentAt }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Runner.Spacing.small) {
            VStack(alignment: .leading, spacing: Runner.Spacing.xsmall) {
                Text(thread.title)
                    .font(Runner.Typography.bodyMedium)
                    .foregroundStyle(Runner.Palette.foreground)
                    .lineLimit(1)

                Text(preview)
                    .font(Runner.Typography.small)
                    .foregroundStyle(Runner.Palette.mutedForeground)
                    .lineLimit(2)
            }

            Spacer(minLength: Runner.Spacing.small)

            Text(AppFormatters.relativeString(for: thread.updatedAt))
                .font(Runner.Typography.caption)
                .foregroundStyle(Runner.Palette.mutedForeground)
                .lineLimit(1)
                .padding(.top, Runner.Spacing.xxsmall)
        }
        .padding(.vertical, Runner.Spacing.snug)
    }

    private var preview: String {
        latestMessage?.body ?? ChatThreadsCopy.emptyThreadPreview
    }
}
