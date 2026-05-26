import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage
    let startsGroup: Bool
    let endsGroup: Bool
    var actionHandler: (ChatMessageAction) -> Void = { _ in }

    private var isUser: Bool {
        message.role == .user
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 7) {
            if isUser {
                Spacer(minLength: 56)
            } else {
                assistantAvatar
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.body)
                    .font(.body)
                    .foregroundStyle(isUser ? .white : .primary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 4) {
                    if message.deliveryState == .sending {
                        ProgressView()
                            .controlSize(.small)
                            .tint(isUser ? .white.opacity(0.72) : .secondary)
                    }

                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(isUser ? .white.opacity(0.72) : .secondary)
                }

                if !message.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(message.actions) { action in
                            Button {
                                actionHandler(action)
                            } label: {
                                Text(action.label)
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(action.style == "destructive" ? .red : .accentColor)
                            .accessibilityIdentifier("chat-action-\(action.decisionRawValue)")
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(bubbleColor, in: bubbleShape)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(message.role.title): \(message.body)")

            if !isUser {
                Spacer(minLength: 56)
            }
        }
    }

    @ViewBuilder
    private var assistantAvatar: some View {
        if endsGroup {
            ChatAvatar(title: "Maraithon", systemImage: "sparkles", size: 28, tint: .accentColor)
        } else {
            Color.clear
                .frame(width: 28, height: 28)
        }
    }

    private var bubbleColor: Color {
        if message.deliveryState == .failed {
            return Color(uiColor: .systemRed).opacity(isUser ? 0.88 : 0.12)
        }
        return isUser ? .accentColor : Color(uiColor: .secondarySystemGroupedBackground)
    }

    private var bubbleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var cornerRadius: CGFloat {
        startsGroup && endsGroup ? 20 : 14
    }

    private var statusText: String {
        switch message.deliveryState {
        case .failed:
            "Not sent"
        default:
            AppFormatters.chatTimeString(for: message.sentAt)
        }
    }
}
