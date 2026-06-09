import SwiftUI
import MessageUI

struct MessageBubble: View {
    @Environment(\.openURL) private var openURL

    let message: ChatMessage
    let startsGroup: Bool
    let endsGroup: Bool
    var actionHandler: (ChatMessageAction) -> Void = { _ in }

    private var isUser: Bool {
        message.role == .user
    }

    private var visibleActions: [ChatMessageAction] {
        guard let cardActionID = message.draftCard?.preparedActionID else {
            return message.actions
        }

        return message.actions.filter { action in
            !(action.actionID == cardActionID && action.decision == .confirm)
        }
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
                        actionHandler: actionHandler,
                        openHandler: { url in
                            openURL(url)
                        }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 56)
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

private struct ChatDraftCardView: View {
    let card: ChatDraftCard
    var actionHandler: (ChatMessageAction) -> Void
    var openHandler: (URL) -> Void

    @State private var editedRecipient: String
    @State private var editedCC: String
    @State private var editedBCC: String
    @State private var editedSubject: String
    @State private var editedBody: String
    @State private var messageComposeDraft: MessageComposeDraft?

    init(
        card: ChatDraftCard,
        actionHandler: @escaping (ChatMessageAction) -> Void,
        openHandler: @escaping (URL) -> Void
    ) {
        self.card = card
        self.actionHandler = actionHandler
        self.openHandler = openHandler
        _editedRecipient = State(initialValue: card.recipient ?? "")
        _editedCC = State(initialValue: card.cc ?? "")
        _editedBCC = State(initialValue: card.bcc ?? "")
        _editedSubject = State(initialValue: card.subject ?? "")
        _editedBody = State(initialValue: card.body ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            Group {
                if card.isTerminal {
                    completedDraft
                } else {
                    switch card.providerKey {
                    case "gmail":
                        emailDraft
                    default:
                        messageDraft
                    }
                }
            }
            .padding(12)

            if card.hasAction && !card.isTerminal {
                Divider()

                HStack(spacing: 8) {
                    if let action = card.primaryAction {
                        Button {
                            actionHandler(action.withDraftEdits(draftEdits))
                        } label: {
                            Label(action.label, systemImage: "paperplane.fill")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!canSend)
                        .accessibilityIdentifier("chat-draft-send")
                    }

                    if let openURL = currentOpenURL {
                        Button {
                            if let draft = currentMessageComposeDraft,
                               MFMessageComposeViewController.canSendText()
                            {
                                messageComposeDraft = draft
                            } else {
                                openHandler(openURL)
                            }
                        } label: {
                            Label(card.openLabel ?? "Open", systemImage: "arrow.up.forward.app.fill")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("chat-draft-open")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(cardBorderColor, lineWidth: 1)
        )
        .onChange(of: card) { _, newCard in
            resetEdits(from: newCard)
        }
        .sheet(item: $messageComposeDraft) { draft in
            MessageComposeView(draft: draft)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ProviderMark(provider: card.providerKey)

            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let status = card.status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if card.isSent {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.green)
                    .accessibilityLabel("Sent")
            } else if card.normalizedStatus == "could not send" {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.red)
                    .accessibilityLabel("Could not send")
            } else if card.primaryAction != nil {
                Image(systemName: "paperplane.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
    }

    private var emailDraft: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                if let from = card.from {
                    draftRow("From", from)
                }

                editableRow("To", text: $editedRecipient, prompt: "recipient")
                editableRow("Cc", text: $editedCC, prompt: "optional")
                editableRow("Bcc", text: $editedBCC, prompt: "optional")
            }

            Divider()

            TextField("Subject", text: $editedSubject, axis: .vertical)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1...3)
                .textInputAutocapitalization(.sentences)
                .accessibilityIdentifier("chat-draft-subject")

            Divider()

            editableBody(minHeight: 132)
        }
    }

    private var messageDraft: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                if let from = card.from {
                    draftRow("From", from)
                }

                if let recipient = card.recipient {
                    draftRow("To", recipient)
                }

                if let workspace = card.workspace {
                    draftRow("Workspace", workspace)
                }

                if let subject = card.subject {
                    draftRow("Subject", subject)
                }
            }

            editableBody(minHeight: 118)
        }
    }

    private var completedDraft: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: card.isSent ? "checkmark.circle.fill" : "info.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)

                Text(completedSummary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                if let from = card.from {
                    draftRow("From", from)
                }

                if let recipient = card.recipient {
                    draftRow("To", recipient)
                }

                if let workspace = card.workspace {
                    draftRow("Workspace", workspace)
                }

                if let subject = card.subject {
                    draftRow("Subject", subject)
                }
            }

            if let body = card.body {
                readOnlyBody(body)
            }
        }
    }

    private var completedSummary: String {
        switch card.normalizedStatus {
        case "sent":
            if let recipient = card.recipient {
                return "Sent to \(recipient)"
            }

            return "Sent"

        case "could not send":
            return "Could not send"

        case "cancelled":
            return "Cancelled"

        case "expired":
            return "Expired"

        default:
            return card.status ?? "Done"
        }
    }

    private var statusColor: Color {
        switch card.normalizedStatus {
        case "sent":
            return .green
        case "could not send":
            return .red
        case "cancelled", "expired":
            return .secondary
        default:
            return .secondary
        }
    }

    private var cardBackground: Color {
        if card.isSent {
            return Color.green.opacity(0.08)
        }

        if card.normalizedStatus == "could not send" {
            return Color.red.opacity(0.08)
        }

        return Color(uiColor: .systemBackground)
    }

    private var cardBorderColor: Color {
        if card.isSent {
            return Color.green.opacity(0.38)
        }

        if card.normalizedStatus == "could not send" {
            return Color.red.opacity(0.36)
        }

        return Color(uiColor: .separator).opacity(0.38)
    }

    private func draftRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)

            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func editableRow(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)

            TextField(prompt, text: text, axis: .vertical)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1...2)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func editableBody(minHeight: CGFloat) -> some View {
        TextEditor(text: $editedBody)
            .font(.subheadline)
            .foregroundStyle(.primary)
            .lineSpacing(2)
            .frame(minHeight: minHeight)
            .padding(6)
            .scrollContentBackground(.hidden)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(uiColor: .separator).opacity(0.22), lineWidth: 1)
            )
            .accessibilityIdentifier("chat-draft-body")
    }

    private func readOnlyBody(_ body: String) -> some View {
        Text(body)
            .font(.subheadline)
            .foregroundStyle(.primary)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(uiColor: .separator).opacity(0.18), lineWidth: 1)
            )
            .accessibilityIdentifier("chat-draft-body-readonly")
    }

    private var draftEdits: [String: JSONValue] {
        switch card.providerKey {
        case "gmail":
            [
                "recipient": .string(clean(editedRecipient) ?? ""),
                "to": .string(clean(editedRecipient) ?? ""),
                "cc": .string(clean(editedCC) ?? ""),
                "bcc": .string(clean(editedBCC) ?? ""),
                "subject": .string(clean(editedSubject) ?? ""),
                "body": .string(clean(editedBody) ?? "")
            ]
        default:
            [
                "body": .string(clean(editedBody) ?? ""),
                "text": .string(clean(editedBody) ?? "")
            ]
        }
    }

    private var currentOpenURL: URL? {
        guard let url = card.openURL else { return nil }

        if card.providerKey == "imessage" {
            return replacingMessageBody(in: url, with: clean(editedBody) ?? "")
        }

        if card.providerKey == "whatsapp" {
            return replacingWhatsAppText(in: url, with: clean(editedBody) ?? "")
        }

        return url
    }

    private var currentMessageComposeDraft: MessageComposeDraft? {
        guard card.providerKey == "imessage",
              let url = card.openURL,
              let recipient = messagesRecipient(from: url)
        else {
            return nil
        }

        return MessageComposeDraft(recipients: [recipient], body: clean(editedBody) ?? "")
    }

    private func replacingMessageBody(in url: URL, with body: String) -> URL {
        let text = url.absoluteString
        let prefix = text.components(separatedBy: "&body=").first ?? text
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "\(prefix)&body=\(encodedBody)") ?? url
    }

    private func replacingWhatsAppText(in url: URL, with body: String) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        var queryItems = components.queryItems ?? []

        if let index = queryItems.firstIndex(where: { $0.name == "text" }) {
            queryItems[index].value = body
        } else {
            queryItems.append(URLQueryItem(name: "text", value: body))
        }

        components.queryItems = queryItems
        return components.url ?? url
    }

    private func messagesRecipient(from url: URL) -> String? {
        let text = url.absoluteString
        guard text.lowercased().hasPrefix("sms:") else { return nil }

        let recipient =
            String(text.dropFirst(4))
                .components(separatedBy: "&body=")
                .first?
                .removingPercentEncoding?
                .trimmingCharacters(in: .whitespacesAndNewlines)

        return recipient?.isEmpty == false ? recipient : nil
    }

    private var canSend: Bool {
        guard clean(editedBody) != nil else { return false }

        if card.providerKey == "gmail" {
            return clean(editedRecipient) != nil
        }

        return true
    }

    private func resetEdits(from newCard: ChatDraftCard) {
        editedRecipient = newCard.recipient ?? ""
        editedCC = newCard.cc ?? ""
        editedBCC = newCard.bcc ?? ""
        editedSubject = newCard.subject ?? ""
        editedBody = newCard.body ?? ""
    }

    private func clean(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct MessageComposeDraft: Identifiable {
    let id = UUID()
    let recipients: [String]
    let body: String
}

private struct MessageComposeView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    let draft: MessageComposeDraft

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.recipients = draft.recipients
        controller.body = draft.body
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        private let dismiss: DismissAction

        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            Task { @MainActor [dismiss] in
                dismiss()
            }
        }
    }
}

private struct ProviderMark: View {
    let provider: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(background)

            if let assetName = assetName {
                Image(assetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: iconName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 34, height: 34)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
        .accessibilityHidden(true)
    }

    private var assetName: String? {
        switch provider {
        case "gmail":
            return "ProviderGmailLogo"
        case "slack":
            return "ProviderSlackLogo"
        case "imessage":
            return "ProviderMessagesLogo"
        default:
            return nil
        }
    }

    private var iconName: String {
        switch provider {
        case "whatsapp":
            return "phone.bubble.left.fill"
        default:
            return "paperplane.fill"
        }
    }

    private var background: Color {
        switch provider {
        case "gmail", "slack", "imessage":
            return Color.white
        case "whatsapp":
            return Color(red: 0.15, green: 0.72, blue: 0.36)
        default:
            return Color.accentColor
        }
    }

    private var borderColor: Color {
        switch provider {
        case "gmail", "slack", "imessage":
            return Color(uiColor: .separator).opacity(0.35)
        default:
            return .clear
        }
    }
}
