import SwiftUI
import MessageUI

struct MessageBubble: View {
    @Environment(\.openURL) private var openURL

    let message: ChatMessage
    let startsGroup: Bool
    let endsGroup: Bool
    var actionHandler: (ChatMessageAction) -> Void = { _ in }
    var prepareHandler: (String) -> Void = { _ in }
    var actionsDisabled = false

    private var isUser: Bool {
        message.role == .user
    }

    private var visibleActions: [ChatMessageAction] {
        guard let cardActionID = message.draftCard?.preparedActionID else {
            return message.actions
        }

        return message.actions.filter { $0.actionID != cardActionID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            bubbleRow

            if !isUser, let draftCard = message.draftCard {
                HStack(alignment: .bottom, spacing: 7) {
                    Color.clear
                        .frame(width: 28, height: 28)

                    ChatDraftCardView(
                        card: draftCard,
                        messageID: message.id,
                        actionsDisabled: actionsDisabled,
                        prepareHandler: prepareHandler,
                        actionHandler: actionHandler,
                        openHandler: { url in
                            openURL(url)
                        }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                }
            }
        }
    }

    private var bubbleRow: some View {
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

                if !isUser, let workSummary = message.workSummary, workSummary.hasVisibleWork {
                    ChatWorkSummaryDisclosure(summary: workSummary)
                        .padding(.top, 2)
                }

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

                if !visibleActions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(visibleActions) { action in
                            Button {
                                actionHandler(action)
                            } label: {
                                Text(action.label)
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(action.style == "destructive" ? .red : .accentColor)
                            .disabled(actionsDisabled)
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

