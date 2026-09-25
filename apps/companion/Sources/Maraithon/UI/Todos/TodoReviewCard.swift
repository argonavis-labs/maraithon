/// The open action card: one reviewable draft or calendar change whose edits
/// stay local until the user confirms. Only server-issued action IDs can
/// execute, and nothing sends on navigation.
import SwiftUI
import AppKit
import AssistantProgressKit

struct TodoReviewCard: View {
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
    @State private var showsConversation = true

    private var locked: Bool { store.decidingActionID != nil }
    private var editable: Bool { draft.isEditable && !locked }
    private var confirmLabel: String { TodoActionCopy.confirmLabel(draft) }
    private var trimmedBody: String { bodyText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var invalidMessage: Bool {
        draft.provider != "calendar" && (trimmedBody.isEmpty || (draft.provider == "gmail" && recipient.isEmpty))
    }
    private var edits: [String: String] {
        ["calendar", "browser"].contains(draft.provider)
            ? [:]
            : ["to": recipient, "subject": subject, "body": bodyText, "cc": cc, "bcc": bcc]
    }
    private var snapshot: TodoConversationStore.DraftEdits {
        .init(recipient: recipient, subject: subject, body: bodyText, cc: cc, bcc: bcc)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                header.runnerCardRow()
                RunnerHairline()
                conversation
                TodoReviewFields(draft: draft, editable: editable, recipient: $recipient, subject: $subject,
                                 cc: $cc, bcc: $bcc, bodyText: $bodyText)
                    .runnerCardRow()
                notices
                RunnerHairline()
                footer.runnerCardRow()
            }
        }
        .onAppear(perform: seed)
        .onChange(of: snapshot) { _, value in store.draftEdits[messageID] = value }
        .confirmationDialog(confirmLabel + "?", isPresented: $confirmsAction, titleVisibility: .visible) {
            Button(confirmLabel) {
                if let id = draft.preparedActionID {
                    Task { await store.decide(id: id, decision: "confirm", edits: edits) }
                }
            }
            Button("Keep reviewing", role: .cancel) { }
        } message: {
            Text(TodoActionCopy.confirmMessage(draft, recipient: recipient))
        }
    }

    @ViewBuilder private var conversation: some View {
        if let messages = draft.conversation, !messages.isEmpty {
            DisclosureGroup("Conversation", isExpanded: $showsConversation) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                            VStack(alignment: .leading, spacing: Tokens.Spacing.xsmall) {
                                HStack {
                                    Text(message.speaker ?? "Contact").font(.caption.bold())
                                    Spacer()
                                    if let date = CompanionConversation.date(from: message.at) {
                                        Text(date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption)
                                    }
                                }.foregroundStyle(.secondary)
                                ChannelMessageText(message.text, provider: draft.provider).font(.callout)
                            }
                            Divider()
                        }
                    }
                }.frame(maxHeight: Tokens.TodoLayout.reviewBodyMaxHeight)
                    .defaultScrollAnchor(.bottom)
            }.runnerCardRow()
            RunnerHairline()
        }
    }

    private var header: some View {
        HStack(spacing: Tokens.Spacing.small) {
            TodoProviderMark(provider: draft.provider, size: Tokens.IconSize.inline)
            Text(TodoActionCopy.reviewTitle(draft))
                .font(Tokens.Typography.bodyMedium)
                .foregroundStyle(Tokens.Palette.foreground)
                .lineLimit(1)
            Spacer(minLength: Tokens.Spacing.small)
            RunnerBadge(text: TodoActionCopy.reviewStatus(draft), tone: TodoActionCopy.reviewTone(draft))
        }
    }

    @ViewBuilder private var notices: some View {
        if let note = draft.deliveryNote {
            Text(note).font(.caption).foregroundStyle(.secondary).runnerCardRow()
        }
        if let localNotice {
            Text(localNotice)
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.mutedForeground)
                .padding(.horizontal, Tokens.SourcesLayout.cardRowHorizontalPadding)
                .padding(.bottom, Tokens.Spacing.small)
        }
        if draft.connectionRequired == true {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.small) {
                Image(systemName: "exclamationmark.triangle")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.cautionText)
                    .accessibilityHidden(true)
                Text(draft.connectionNotice ?? "Reconnect this account to continue.")
                    .font(Tokens.Typography.small)
                    .foregroundStyle(Tokens.Palette.cautionText)
                    .fixedSize(horizontal: false, vertical: true)
                if let raw = draft.connectionURL, let url = URL(string: raw), url.scheme == "https" {
                    Link(draft.connectionLabel ?? "Enable Google permission", destination: url)
                        .font(Tokens.Typography.small)
                }
            }
            .padding(.horizontal, Tokens.SourcesLayout.cardRowHorizontalPadding)
            .padding(.bottom, Tokens.Spacing.small)
        }
    }

    private var footer: some View {
        HStack(spacing: Tokens.Spacing.small) {
            if draft.provider != "calendar" {
                Button("Copy", systemImage: "doc.on.doc") { copy() }
                    .buttonStyle(RunnerButtonStyle(.plain))
            }
            if draft.provider == "imessage", draft.preparedActionID == nil, !TodoActionPlan.isTerminal(draft) {
                Button("Open in Messages", systemImage: "message") { openMessages() }
                    .buttonStyle(RunnerButtonStyle(.plain))
                    .disabled(trimmedBody.isEmpty)
            }
            Spacer(minLength: Tokens.Spacing.small)
            if locked, store.decidingActionID == draft.preparedActionID {
                ProgressView().controlSize(.small).accessibilityLabel("Applying action")
            }
            if let actionID = draft.preparedActionID {
                Button("Cancel") {
                    Task { await store.decide(id: actionID, decision: "reject", edits: [:]) }
                }
                .buttonStyle(RunnerButtonStyle(.plain))
                .disabled(locked)
                .help("Cancel this action")
                Button(confirmLabel) { confirmsAction = true }
                    .buttonStyle(RunnerButtonStyle(.primary, compact: true))
                    .disabled(locked || invalidMessage || draft.connectionRequired == true)
            } else if draft.provider == "gmail", draft.editable == true {
                Button("Prepare to send") {
                    Task {
                        await store.send(TodoActionCopy.prepareEmailPrompt(draft, recipient: recipient, subject: subject,
                                                                            cc: cc, bcc: bcc, body: bodyText))
                    }
                }
                .buttonStyle(RunnerButtonStyle(.primary, compact: true))
                .disabled(store.isSending || invalidMessage || draft.connectionRequired == true)
            }
        }
    }

    private func seed() {
        let saved = store.draftEdits[messageID]
        recipient = saved?.recipient ?? draft.recipient ?? ""
        subject = saved?.subject ?? draft.subject ?? ""
        bodyText = saved?.body ?? draft.body ?? ""
        cc = saved?.cc ?? draft.cc ?? ""
        bcc = saved?.bcc ?? draft.bcc ?? ""
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        localNotice = NSPasteboard.general.setString(bodyText, forType: .string)
            ? "Copied"
            : "Could not copy. Select the draft text to copy it."
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
