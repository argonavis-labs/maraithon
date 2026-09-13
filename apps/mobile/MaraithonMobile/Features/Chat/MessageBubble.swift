import SwiftUI
import MessageUI

/// One transcript turn. Assistant replies sit as plain text on the workspace
/// ground under a "Maraithon" label; user turns sit in a tinted hairline card
/// on the trailing edge, like the web workspace rather than iMessage.
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

    private var isFailed: Bool {
        message.deliveryState == .failed
    }

    private var visibleActions: [ChatMessageAction] {
        guard let cardActionID = message.draftCard?.preparedActionID else {
            return message.actions
        }

        return message.actions.filter { $0.actionID != cardActionID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Runner.Spacing.small) {
            if isUser {
                userRow
            } else {
                assistantRow
            }

            if !isUser, let draftCard = message.draftCard {
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

    private var assistantRow: some View {
        VStack(alignment: .leading, spacing: Runner.Spacing.xsmall) {
            if startsGroup {
                ChatSpeakerLabel(title: "Maraithon")
            }

            Text(message.body)
                .font(Runner.Typography.body)
                .foregroundStyle(isFailed ? Runner.Palette.destructiveText : Runner.Palette.foreground)
                .fixedSize(horizontal: false, vertical: true)

            if let workSummary = message.workSummary, workSummary.hasVisibleWork {
                ChatWorkSummaryDisclosure(summary: workSummary)
                    .padding(.top, Runner.Spacing.xxsmall)
            }

            statusLine

            actionRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.role.title): \(message.body)")
    }

    private var userRow: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: Runner.Spacing.xsmall) {
                Text(message.body)
                    .font(Runner.Typography.body)
                    .foregroundStyle(isFailed ? Runner.Palette.destructiveText : Runner.Palette.foreground)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                statusLine

                actionRow
            }
            .padding(.horizontal, Runner.Spacing.tight)
            .padding(.vertical, Runner.Spacing.snug)
            .background(
                isFailed ? Runner.Palette.badgeFill(Runner.Palette.hueRed) : Runner.Palette.selected,
                in: RoundedRectangle(cornerRadius: Runner.Radius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Runner.Radius.card, style: .continuous)
                    .stroke(Runner.Palette.border, lineWidth: Runner.Stroke.hairline)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(message.role.title): \(message.body)")
            .containerRelativeFrame(.horizontal, alignment: .trailing) { length, _ in
                length * 0.85
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: Runner.Spacing.xsmall) {
            if message.deliveryState == .sending {
                ProgressView()
                    .controlSize(.small)
                    .tint(Runner.Palette.mutedForeground)
            }

            Text(statusText)
                .font(Runner.Typography.caption)
                .foregroundStyle(isFailed ? Runner.Palette.destructiveText : Runner.Palette.mutedForeground)
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        if !visibleActions.isEmpty {
            HStack(spacing: Runner.Spacing.small) {
                ForEach(visibleActions) { action in
                    Button {
                        actionHandler(action)
                    } label: {
                        Text(action.label)
                            .font(Runner.Typography.smallMedium)
                    }
                    .buttonStyle(RunnerButtonStyle(action.style == "destructive" ? .destructive : .primary, compact: true))
                    .disabled(actionsDisabled)
                    .accessibilityIdentifier("chat-action-\(action.decisionRawValue)")
                }
            }
            .padding(.top, Runner.Spacing.xsmall)
        }
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
