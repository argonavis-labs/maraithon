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
    @State private var showsSourceContext = false
    @State private var showsCopyFields = false

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
        RunnerCard {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: Runner.Spacing.snug) {
                    ProviderMark(provider: card.providerKey)
                    VStack(alignment: .leading, spacing: Runner.Spacing.xsmall) {
                        Text(card.title)
                            .font(Runner.Typography.smallMedium)
                            .foregroundStyle(Runner.Palette.foreground)
                            .multilineTextAlignment(.leading)
                        if let status = card.status {
                            RunnerBadge(text: status, tone: statusTone, wraps: true)
                        }
                    }
                    Spacer(minLength: Runner.Spacing.xsmall)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(Runner.Typography.caption)
                        .foregroundStyle(Runner.Palette.mutedForeground)
                        .accessibilityHidden(true)
                }
                .runnerCardRow()
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("\(isExpanded ? "Collapse" : "Review") \(card.title)")

            if isExpanded {
                RunnerHairline()
                VStack(alignment: .leading, spacing: Runner.Spacing.tight) {
                    if card.providerKey == "calendar" { calendarDetails } else { messageDetails }
                    if !card.isTerminal, !card.conversation.isEmpty || !card.participants.isEmpty {
                        CardDisclosure(title: "Source context", isExpanded: $showsSourceContext) {
                            if !card.participants.isEmpty { CardParticipantsSection(participants: card.participants) }
                            if !card.conversation.isEmpty { CardConversationSection(messages: card.conversation) }
                        }
                    }
                    if let notice = card.connectionNotice, card.connectionRequired == true {
                        Text(notice)
                            .font(Runner.Typography.caption)
                            .foregroundStyle(Runner.Palette.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if card.connectionRequired == true, let url = card.connectionURL, url.scheme == "https" {
                        Link(card.connectionLabel ?? "Enable Google permission", destination: url)
                            .font(Runner.Typography.smallMedium)
                            .foregroundStyle(Runner.Palette.accent)
                    }
                    if let localNotice {
                        Text(localNotice)
                            .font(Runner.Typography.caption)
                            .foregroundStyle(Runner.Palette.mutedForeground)
                    }
                    actionButtons
                }
                .runnerCardRow()
            }
        }
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
        VStack(alignment: .leading, spacing: Runner.Spacing.snug) {
            if let from = card.from { detail("From", from) }
            if isEditable && card.providerKey == "gmail" {
                editableRow("To", text: $recipient)
                editableRow("Subject", text: $subject)
                CardDisclosure(title: "Cc and Bcc", isExpanded: $showsCopyFields) {
                    editableRow("Cc", text: $cc)
                    editableRow("Bcc", text: $bcc)
                }
            } else {
                if let name = card.recipientName { detail("To", "\(name) · \(recipient)") }
                else if !recipient.isEmpty { detail("To", recipient) }
                if !subject.isEmpty { detail("Subject", subject) }
            }
            if let workspace = card.workspace { detail("Workspace", workspace) }
            if isEditable {
                TextField("Draft message", text: $bodyText, axis: .vertical)
                    .lineLimit(4...16)
                    .font(Runner.Typography.body)
                    .foregroundStyle(Runner.Palette.foreground)
                    .padding(Runner.Spacing.snug)
                    .background(Runner.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Runner.Radius.control, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Runner.Radius.control, style: .continuous)
                            .stroke(Runner.Palette.border, lineWidth: Runner.Stroke.hairline)
                    }
                    .disabled(actionsDisabled).accessibilityIdentifier("chat-draft-body")
            } else if let body = card.body {
                Text(body)
                    .font(Runner.Typography.small)
                    .foregroundStyle(Runner.Palette.foreground)
                    .textSelection(.enabled)
            }
        }
    }

    private var calendarDetails: some View {
        VStack(alignment: .leading, spacing: Runner.Spacing.snug) {
            if let from = card.from { detail("Calendar", from) }
            if let start = card.startAt { detail("Starts", dateLabel(start)) }
            if let end = card.endAt { detail("Ends", dateLabel(end)) }
            if let timezone = card.timezone { detail("Time zone", timezone) }
            if let body = card.body, !body.isEmpty {
                Text(body)
                    .font(Runner.Typography.small)
                    .foregroundStyle(Runner.Palette.foreground)
                    .textSelection(.enabled)
            }
        }
    }

    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: Runner.Spacing.snug) {
            if !card.isTerminal, let action = card.primaryAction {
                HStack(spacing: Runner.Spacing.small) {
                    Button(actionLabel, systemImage: card.providerKey == "browser" ? "globe" : card.providerKey == "calendar" ? "calendar" : "paperplane") {
                        confirmsAction = true
                    }.buttonStyle(RunnerButtonStyle(.primary, compact: true))
                        .disabled(actionsDisabled || !canPrepare || card.connectionRequired == true)
                        .accessibilityIdentifier("chat-draft-send")
                    Button("Cancel action") {
                        actionHandler(ChatMessageAction(
                            actionID: action.actionID, kind: action.kind, label: "Cancel action",
                            decisionRawValue: ChatActionDecision.reject.rawValue, style: "destructive"
                        ))
                    }.buttonStyle(RunnerButtonStyle(.destructive, compact: true))
                        .disabled(actionsDisabled)
                }
            }
            if !card.isTerminal, card.providerKey == "gmail", card.primaryAction == nil, card.editable == true {
                Button("Prepare to send", systemImage: "envelope") {
                    prepareHandler("Save this reviewed email as a Gmail draft and prepare its approval card. Do not send. Keep the original thread context. From: \(card.from ?? "the source account")\nTo: \(recipient)\nSubject: \(subject)\nCc: \(cc)\nBcc: \(bcc)\n\n\(bodyText)")
                }.buttonStyle(RunnerButtonStyle(.secondary, compact: true))
                    .disabled(actionsDisabled || !canPrepare || card.connectionRequired == true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Runner.Spacing.small) { handoffButtons }
                VStack(alignment: .leading, spacing: Runner.Spacing.small) { handoffButtons }
            }.buttonStyle(RunnerButtonStyle(.secondary, compact: true))
        }
        .font(Runner.Typography.smallMedium)
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

    /// Badge tone for the card's status line: closed-out states read green,
    /// failures red, in-flight amber, and anything still under review neutral.
    private var statusTone: RunnerBadge.Tone {
        let status = (card.status ?? "").lowercased()
        if status.contains("could not") || status.contains("cancel") || status.contains("expired") { return .red }
        if status.contains("running") || status.contains("check") { return .amber }
        if card.isTerminal { return .emerald }
        return .zinc
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
        VStack(alignment: .leading, spacing: Runner.Spacing.xsmall) {
            RunnerSectionLabel(label)
            Text(value)
                .font(Runner.Typography.small)
                .foregroundStyle(Runner.Palette.foreground)
                .textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func editableRow(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Runner.Spacing.xsmall) {
            RunnerSectionLabel(label)
            TextField(label, text: text, axis: .vertical)
                .font(Runner.Typography.small)
                .foregroundStyle(Runner.Palette.foreground)
                .lineLimit(1...3)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, Runner.Spacing.snug)
                .padding(.vertical, Runner.Spacing.small)
                .background(Runner.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Runner.Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Runner.Radius.control, style: .continuous)
                        .stroke(Runner.Palette.border, lineWidth: Runner.Stroke.hairline)
                }
                .disabled(actionsDisabled)
        }
    }
}

/// Quiet expandable section inside a card: section label with a chevron,
/// content revealed below. Replaces the system disclosure chrome.
private struct CardDisclosure<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Runner.Spacing.small) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Runner.Spacing.compact) {
                    RunnerSectionLabel(title)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(Runner.Typography.micro)
                        .foregroundStyle(Runner.Palette.mutedForeground)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                VStack(alignment: .leading, spacing: Runner.Spacing.snug) {
                    content()
                }
            }
        }
    }
}
