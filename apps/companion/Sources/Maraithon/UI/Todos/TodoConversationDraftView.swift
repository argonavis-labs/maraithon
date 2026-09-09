/// Inline action review keeps edited text local until an explicit send or native composer action.
import SwiftUI
import AppKit

struct TodoConversationDraftView: View {
    let draft: CompanionConversationDraft
    let store: TodoConversationStore
    let messageID: String
    @State private var recipient = ""
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var cc = ""
    @State private var bcc = ""
    @State private var localNotice: String?
    @State private var confirmsAction = false
    @State private var sharingService: NSSharingService?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            Divider()
            HStack(spacing: Tokens.Spacing.small) {
                TodoProviderMark(provider: draft.provider)
                Text(draft.title ?? "Prepared action").font(.headline)
            }
            if let status = draft.status { Text(status).font(.caption).foregroundStyle(.secondary) }
            if draft.provider == "calendar" {
                calendarDetails
            } else {
                messageDetails
            }
            if let localNotice { Text(localNotice).font(.caption).foregroundStyle(.secondary) }
            if draft.connectionRequired == true {
                if let notice = draft.connectionNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                if let raw = draft.connectionURL, let url = URL(string: raw), url.scheme == "https" {
                    Link(draft.connectionLabel ?? "Enable Google permission", destination: url).font(.callout)
                }
            }
            HStack(spacing: Tokens.Spacing.small) {
                if draft.provider != "calendar" {
                    Button("Copy", systemImage: "doc.on.doc") { copy() }
                }
                if draft.provider == "imessage" {
                    Button("Open in Messages", systemImage: "message") { openMessages() }
                        .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let actionID = draft.preparedActionID {
                    Button(actionLabel, systemImage: symbol) { confirmsAction = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.decidingActionID != nil || invalidMessage || draft.connectionRequired == true)
                    Button("Cancel action", systemImage: "xmark") {
                        Task { await store.decide(id: actionID, decision: "reject", edits: [:]) }
                    }.disabled(store.decidingActionID != nil)
                }
                if draft.provider == "gmail", draft.preparedActionID == nil, draft.editable == true {
                    Button("Prepare to send", systemImage: "envelope") {
                        Task { await store.send("Save this reviewed email as a Gmail draft and prepare its approval card. Do not send. Keep the original thread context. From: \(draft.from ?? "the source account")\nTo: \(recipient)\nSubject: \(subject)\nCc: \(cc)\nBcc: \(bcc)\n\n\(bodyText)") }
                    }.disabled(store.isSending || invalidMessage || draft.connectionRequired == true)
                }
                if store.decidingActionID == draft.preparedActionID, store.decidingActionID != nil {
                    ProgressView().controlSize(.small).accessibilityLabel("Applying action")
                }
            }
            .controlSize(.small)
        }
        .onAppear {
            let saved = store.draftEdits[messageID]
            recipient = saved?.recipient ?? draft.recipient ?? ""
            subject = saved?.subject ?? draft.subject ?? ""
            bodyText = saved?.body ?? draft.body ?? ""
            cc = saved?.cc ?? draft.cc ?? ""
            bcc = saved?.bcc ?? draft.bcc ?? ""
        }
        .onChange(of: snapshot) { _, value in store.draftEdits[messageID] = value }
        .confirmationDialog(actionLabel + "?", isPresented: $confirmsAction, titleVisibility: .visible) {
            Button(actionLabel) {
                if let id = draft.preparedActionID {
                    Task { await store.decide(id: id, decision: "confirm", edits: edits) }
                }
            }
            Button("Keep reviewing", role: .cancel) { }
        } message: {
            Text(draft.provider == "browser" ? "Run the exact browser step shown here on your Mac." : draft.provider == "calendar" ? "Save the calendar change shown here." : "Send the reviewed message to \(recipient).")
        }
    }

    private var messageDetails: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            if let from = draft.from { LabeledContent("From", value: from).font(.callout) }
            if editable && draft.provider == "gmail" {
                TextField("To", text: $recipient).textFieldStyle(.roundedBorder)
                TextField("Subject", text: $subject).textFieldStyle(.roundedBorder)
                DisclosureGroup("Cc and Bcc") {
                    TextField("Cc", text: $cc).textFieldStyle(.roundedBorder)
                    TextField("Bcc", text: $bcc).textFieldStyle(.roundedBorder)
                }.font(.callout)
            } else if !recipient.isEmpty {
                LabeledContent("To", value: draft.recipientName.map { "\($0) · \(recipient)" } ?? recipient)
                    .font(.callout)
                if !subject.isEmpty { LabeledContent("Subject", value: subject).font(.callout) }
            }
            if editable {
                TextEditor(text: $bodyText)
                    .frame(height: Tokens.Layout.todoDraftBodyHeight)
                    .accessibilityLabel("Draft message")
                    .disabled(store.decidingActionID != nil)
            } else {
                ScrollView { Text(bodyText).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(maxHeight: Tokens.Layout.todoDraftBodyHeight)
            }
        }
    }

    private var calendarDetails: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            if let from = draft.from { LabeledContent("Calendar", value: from) }
            if let start = draft.startAt { LabeledContent("Starts", value: dateLabel(start)) }
            if let end = draft.endAt { LabeledContent("Ends", value: dateLabel(end)) }
            if let timezone = draft.timezone { LabeledContent("Time zone", value: timezone) }
            if let body = draft.body, !body.isEmpty { Text(body).textSelection(.enabled) }
        }.font(.callout)
    }

    private var snapshot: TodoConversationStore.DraftEdits {
        .init(recipient: recipient, subject: subject, body: bodyText, cc: cc, bcc: bcc)
    }
    private var editable: Bool { draft.isEditable }
    private var invalidMessage: Bool {
        draft.provider != "calendar" && (bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (draft.provider == "gmail" && recipient.isEmpty))
    }
    private var edits: [String: String] {
        ["calendar", "browser"].contains(draft.provider) ? [:] : ["to": recipient, "subject": subject, "body": bodyText, "cc": cc, "bcc": bcc]
    }
    private var symbol: String { draft.provider == "browser" ? "globe" : draft.provider == "calendar" ? "calendar" : (draft.provider == "imessage" ? "message" : "envelope") }
    private var actionLabel: String { draft.provider == "gmail" ? "Send email" : (draft.sendLabel ?? "Confirm action") }

    private func dateLabel(_ raw: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: raw) else { return raw }
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        formatter.timeZone = draft.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
        return formatter.string(from: date)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        localNotice = NSPasteboard.general.setString(bodyText, forType: .string) ? "Copied" : "Could not copy. Select the draft text to copy it."
    }

    private func openMessages() {
        guard !recipient.isEmpty, let service = NSSharingService(named: .composeMessage),
              service.canPerform(withItems: [bodyText]) else {
            localNotice = "Messages is unavailable. You can copy the draft instead."
            return
        }
        sharingService = service
        service.recipients = [recipient]
        service.perform(withItems: [bodyText])
        localNotice = "Opened for review in Messages."
    }
}
