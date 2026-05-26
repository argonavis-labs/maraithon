import SwiftUI

struct ChatThreadRow: View {
    let thread: ChatThread

    private var latestMessage: ChatMessage? {
        thread.sortedMessages.last
    }

    var body: some View {
        HStack(spacing: 12) {
            ChatAvatar(title: thread.title, systemImage: thread.messages.isEmpty ? "bubble.left" : nil)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(thread.title)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(AppFormatters.relativeString(for: thread.updatedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
    }

    private var preview: String {
        latestMessage?.body ?? "No messages yet"
    }
}
