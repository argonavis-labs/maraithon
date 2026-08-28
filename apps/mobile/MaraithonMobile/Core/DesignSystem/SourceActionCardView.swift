import MessageUI
import SwiftUI
import UIKit

/// Action card for a work item's source channel: shows the full suggested
/// wording with copy support and a one-tap path back into the source app.
struct SourceActionCardView: View {
    let action: TodoSourceAction
    let onSend: ((String, String?) async throws -> Void)?

    @Environment(\.openURL) private var openURL
    @State private var messageComposeDraft: MessageComposeDraft?
    @State private var didCopyDraft = false
    @State private var draftText: String
    @State private var subject: String
    @State private var isSending = false
    @State private var didSend = false
    @State private var sendError: String?
    @State private var confirmsSend = false

    init(
        action: TodoSourceAction,
        onSend: ((String, String?) async throws -> Void)? = nil
    ) {
        self.action = action
        self.onSend = onSend
        _draftText = State(initialValue: action.draftText ?? "")
        _subject = State(initialValue: action.subject ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ProviderMark(provider: action.provider ?? "")

                VStack(alignment: .leading, spacing: 2) {
                    Text(action.headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let subtitle = action.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)
            }

            if !action.participants.isEmpty {
                CardParticipantsSection(participants: action.participants)
            }

            if !action.conversation.isEmpty {
                CardConversationSection(messages: action.conversation, maxMessages: 12)
            }

            if action.hasDraft {
                if !action.conversation.isEmpty {
                    Text(SourceActionCopy.draftSectionTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }

                if action.provider == "gmail" {
                    TextField(SourceActionCopy.subjectTitle, text: $subject)
                        .font(.subheadline.weight(.medium))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("source-action-subject")
                }

                TextEditor(text: $draftText)
                    .font(.subheadline)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: action.provider == "gmail" ? 132 : 88)
                    .padding(8)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityIdentifier("source-action-reply-body")

                if let sendError {
                    Label(sendError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                if action.hasDraft {
                    Button {
                        copyDraft()
                    } label: {
                        Label(
                            didCopyDraft ? SourceActionCopy.copiedTitle : SourceActionCopy.copyTitle,
                            systemImage: didCopyDraft ? "checkmark" : "doc.on.doc"
                        )
                        .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("source-action-copy-draft")
                }

                if canSendDirect {
                    Button {
                        confirmsSend = true
                    } label: {
                        Label(
                            didSend ? SourceActionCopy.sentTitle : sendButtonTitle,
                            systemImage: didSend ? "checkmark.circle.fill" : "paperplane.fill"
                        )
                        .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isSending || didSend || draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("source-action-send")
                }

                if hasOpenAction {
                    Button {
                        openSource()
                    } label: {
                        Label(
                            action.openLabel ?? SourceActionCopy.openFallbackTitle,
                            systemImage: "arrow.up.forward.app.fill"
                        )
                        .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("source-action-open")
                }

                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .sheet(item: $messageComposeDraft) { draft in
            MessageComposeView(draft: draft)
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: $confirmsSend,
            titleVisibility: .visible
        ) {
            Button(sendButtonTitle) {
                Task { await sendDirect() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SourceActionCopy.confirmationMessage)
        }
    }

    private var canComposeMessage: Bool {
        action.prefersMessageCompose && MFMessageComposeViewController.canSendText()
    }

    private var hasOpenAction: Bool {
        action.openURL != nil || canComposeMessage
    }

    private var canSendDirect: Bool {
        onSend != nil && ["gmail", "slack"].contains(action.provider) && action.hasDraft
    }

    private var sendButtonTitle: String {
        action.provider == "slack" ? SourceActionCopy.postTitle : SourceActionCopy.sendEmailTitle
    }

    private var confirmationTitle: String {
        action.provider == "slack" ? SourceActionCopy.confirmPostTitle : SourceActionCopy.confirmEmailTitle
    }

    private func openSource() {
        if canComposeMessage, let handle = action.recipientHandle {
            messageComposeDraft = MessageComposeDraft(
                recipients: [handle],
                body: action.draftText ?? ""
            )
        } else if let url = action.openURL {
            openURL(url)
        }
    }

    private func copyDraft() {
        UIPasteboard.general.string = draftText
        didCopyDraft = true

        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopyDraft = false
        }
    }

    @MainActor
    private func sendDirect() async {
        guard let onSend, !isSending else { return }
        isSending = true
        sendError = nil
        defer { isSending = false }

        do {
            try await onSend(draftText, subject.isEmpty ? nil : subject)
            didSend = true
        } catch {
            sendError = MobileErrorCopy.message(for: error)
        }
    }
}

enum SourceActionCopy {
    static let copyTitle = "Copy draft"
    static let copiedTitle = "Copied"
    static let openFallbackTitle = "Open source"
    static let draftSectionTitle = "Suggested reply"
    static let subjectTitle = "Subject"
    static let sendEmailTitle = "Send email"
    static let postTitle = "Post"
    static let sentTitle = "Sent"
    static let confirmEmailTitle = "Send this email?"
    static let confirmPostTitle = "Post this message?"
    static let confirmationMessage = "This will send through your connected account."
}
