import MessageUI
import SwiftUI

/// Provider review cards: account, recipient, editable content, explicit action.
/// Scene storage retains local edits; the server owns execution and outcomes.
struct ChatDraftCardView: View {
    let card: ChatDraftCard
    let actionsDisabled: Bool
    let prepareHandler: (String) -> Void
    let actionHandler: (ChatMessageAction) -> Void
    let openHandler: (URL) -> Void
    @SceneStorage private var recipient: String
    @SceneStorage private var cc: String
    @SceneStorage private var bcc: String
    @SceneStorage private var subject: String
    @SceneStorage private var bodyText: String
    @SceneStorage private var isExpanded: Bool
    @State private var messageComposeDraft: MessageComposeDraft?
    @State private var localNotice: String?
    @State private var confirmsAction = false

    init(card: ChatDraftCard, messageID: UUID, actionsDisabled: Bool,
         prepareHandler: @escaping (String) -> Void,
         actionHandler: @escaping (ChatMessageAction) -> Void,
         openHandler: @escaping (URL) -> Void) {
        self.card = card
        self.actionsDisabled = actionsDisabled
        self.prepareHandler = prepareHandler
        self.actionHandler = actionHandler
        self.openHandler = openHandler
        let key = "chat.review.\(messageID.uuidString)"
        _recipient = SceneStorage(wrappedValue: card.recipient ?? "", key + ".to")
        _cc = SceneStorage(wrappedValue: card.cc ?? "", key + ".cc")
        _bcc = SceneStorage(wrappedValue: card.bcc ?? "", key + ".bcc")
        _subject = SceneStorage(wrappedValue: card.subject ?? "", key + ".subject")
        _bodyText = SceneStorage(wrappedValue: card.body ?? "", key + ".body")
        _isExpanded = SceneStorage(wrappedValue: false, key + ".expanded")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 10) {
                    ProviderMark(provider: card.providerKey)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(card.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        if let status = card.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(12).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("\(isExpanded ? "Collapse" : "Review") \(card.title)")

            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    if card.providerKey == "calendar" { calendarDetails } else { messageDetails }
                    if !card.isTerminal, !card.conversation.isEmpty || !card.participants.isEmpty {
                        DisclosureGroup("Source context") {
                            if !card.participants.isEmpty { CardParticipantsSection(participants: card.participants) }
                            if !card.conversation.isEmpty { CardConversationSection(messages: card.conversation) }
                        }.font(.subheadline)
                    }
                    if let notice = card.connectionNotice, card.connectionRequired == true {
                        Text(notice).font(.footnote).foregroundStyle(.secondary)
                    }
                    if card.connectionRequired == true, let url = card.connectionURL, url.scheme == "https" {
                        Link(card.connectionLabel ?? "Enable Google permission", destination: url).font(.subheadline)
                    }
                    if let localNotice { Text(localNotice).font(.footnote).foregroundStyle(.secondary) }
                    actionButtons
                }.padding(12)
            }
        }
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(uiColor: .separator).opacity(0.3)))
        .sheet(item: $messageComposeDraft) { draft in MessageComposeView(draft: draft) }
        .confirmationDialog(actionLabel + "?", isPresented: $confirmsAction, titleVisibility: .visible) {
            Button(actionLabel) {
                if let action = card.primaryAction, !actionsDisabled {
                    actionHandler(action.withDraftEdits(draftEdits))
                }
            }
            Button("Keep reviewing", role: .cancel) {}
        } message: {
            Text(card.providerKey == "browser" ? "Run the exact browser step shown here on your Mac." : card.providerKey == "calendar" ? "Save the calendar change shown here." : "Send the reviewed message to \(recipient).")
        }
    }

    private var messageDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let from = card.from { detail("From", from) }
            if isEditable && card.providerKey == "gmail" {
                editableRow("To", text: $recipient)
                editableRow("Subject", text: $subject)
                DisclosureGroup("Cc and Bcc") {
                    editableRow("Cc", text: $cc)
                    editableRow("Bcc", text: $bcc)
                }.font(.subheadline)
            } else {
                if let name = card.recipientName { detail("To", "\(name) · \(recipient)") }
                else if !recipient.isEmpty { detail("To", recipient) }
                if !subject.isEmpty { detail("Subject", subject) }
            }
            if let workspace = card.workspace { detail("Workspace", workspace) }
            if isEditable {
                TextField("Draft message", text: $bodyText, axis: .vertical)
                    .lineLimit(4...16).font(.body).padding(10)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    .disabled(actionsDisabled).accessibilityIdentifier("chat-draft-body")
            } else if let body = card.body {
                Text(body).font(.subheadline).textSelection(.enabled)
            }
        }
    }

    private var calendarDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let from = card.from { detail("Calendar", from) }
            if let start = card.startAt { detail("Starts", dateLabel(start)) }
            if let end = card.endAt { detail("Ends", dateLabel(end)) }
            if let timezone = card.timezone { detail("Time zone", timezone) }
            if let body = card.body, !body.isEmpty { Text(body).font(.subheadline).textSelection(.enabled) }
        }
    }

    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !card.isTerminal, let action = card.primaryAction {
                HStack {
                    Button(actionLabel, systemImage: card.providerKey == "browser" ? "globe" : card.providerKey == "calendar" ? "calendar" : "paperplane") {
                        confirmsAction = true
                    }.buttonStyle(.borderedProminent)
                        .disabled(actionsDisabled || !canPrepare || card.connectionRequired == true)
                        .accessibilityIdentifier("chat-draft-send")
                    Button("Cancel action") {
                        actionHandler(ChatMessageAction(
                            actionID: action.actionID, kind: action.kind, label: "Cancel action",
                            decisionRawValue: ChatActionDecision.reject.rawValue, style: "destructive"
                        ))
                    }.disabled(actionsDisabled)
                }
            }
            if !card.isTerminal, card.providerKey == "gmail", card.primaryAction == nil, card.editable == true {
                Button("Prepare to send", systemImage: "envelope") {
                    prepareHandler("Save this reviewed email as a Gmail draft and prepare its approval card. Do not send. Keep the original thread context. From: \(card.from ?? "the source account")\nTo: \(recipient)\nSubject: \(subject)\nCc: \(cc)\nBcc: \(bcc)\n\n\(bodyText)")
                }.buttonStyle(.bordered)
                    .disabled(actionsDisabled || !canPrepare || card.connectionRequired == true)
            }
            ViewThatFits(in: .horizontal) {
                HStack { handoffButtons }
                VStack(alignment: .leading) { handoffButtons }
            }.buttonStyle(.bordered)
        }.font(.subheadline)
    }

    @ViewBuilder private var handoffButtons: some View {
        if card.providerKey != "calendar" {
            Button("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = card.isTerminal ? card.body : bodyText
                localNotice = "Copied"
            }
        }
        if !card.isTerminal, card.providerKey == "imessage", messageRecipient != nil {
            Button("Open in Messages", systemImage: "message") { openMessages() }
                .disabled(!canPrepare).accessibilityIdentifier("chat-draft-open")
        } else if !card.isTerminal, let url = currentOpenURL {
            Button(card.openLabel ?? "Open", systemImage: "arrow.up.forward.app") { openHandler(url) }
        }
    }

    private var isEditable: Bool {
        card.providerKey != "browser" && !card.isTerminal && (card.editable == true || card.primaryAction != nil || ["imessage", "whatsapp"].contains(card.providerKey))
    }
    private var canPrepare: Bool {
        if card.providerKey == "calendar" { return true }
        return !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (card.providerKey != "gmail" || !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private var actionLabel: String {
        card.providerKey == "gmail" ? "Send email" : (card.sendLabel ?? "Confirm action")
    }
    private var draftEdits: [String: JSONValue] {
        if ["calendar", "browser"].contains(card.providerKey) { return [:] }
        if card.providerKey == "gmail" {
            return ["to": .string(recipient), "recipient": .string(recipient), "subject": .string(subject),
                    "body": .string(bodyText), "cc": .string(cc), "bcc": .string(bcc)]
        }
        return ["body": .string(bodyText), "text": .string(bodyText)]
    }
    private var messageRecipient: String? {
        let raw = card.recipient ?? card.openURL.flatMap { url -> String? in
            guard url.scheme == "sms" else { return nil }
            return String(url.absoluteString.dropFirst(4)).components(separatedBy: CharacterSet(charactersIn: "?&")).first?.removingPercentEncoding
        }
        guard let raw else { return nil }
        return raw.range(of: #"^\+?[0-9]{7,15}$|^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$"#, options: .regularExpression) != nil ? raw : nil
    }
    private func openMessages() {
        guard let recipient = messageRecipient, MFMessageComposeViewController.canSendText() else {
            localNotice = "Messages is unavailable on this device. You can copy the draft."
            return
        }
        messageComposeDraft = MessageComposeDraft(recipients: [recipient], body: bodyText)
        localNotice = "Opened for review in Messages."
    }
    private var currentOpenURL: URL? {
        guard let url = card.openURL, card.providerKey != "imessage" else { return nil }
        if card.providerKey == "whatsapp", var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            var items = components.queryItems ?? []
            items.removeAll { $0.name == "text" }
            items.append(URLQueryItem(name: "text", value: bodyText))
            components.queryItems = items
            return components.url
        }
        return url
    }
    private func dateLabel(_ raw: String) -> String {
        let parser = ISO8601DateFormatter()
        let date = parser.date(from: raw) ?? {
            parser.formatOptions.insert(.withFractionalSeconds)
            return parser.date(from: raw)
        }()
        guard let date else { return raw }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = card.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
        return formatter.string(from: date)
    }
    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.subheadline).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func editableRow(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField(label, text: text, axis: .vertical)
                .font(.subheadline).lineLimit(1...3).textInputAutocapitalization(.never)
                .autocorrectionDisabled().disabled(actionsDisabled)
        }
    }
}
