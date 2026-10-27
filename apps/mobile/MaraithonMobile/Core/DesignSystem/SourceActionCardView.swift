import MessageUI
import SwiftUI
import UIKit

/// Action card for a work item's source channel: shows the full suggested
/// wording with copy support and a one-tap path back into the source app.
struct SourceActionCardView: View {
    let action: TodoSourceAction
    let showsContext: Bool
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
        showsContext: Bool = true,
        onSend: ((String, String?) async throws -> Void)? = nil
    ) {
        self.action = action
        self.showsContext = showsContext
        self.onSend = onSend
        _draftText = State(initialValue: action.draftText ?? "")
        _subject = State(initialValue: action.subject ?? "")
    }

    var body: some View {
        RunnerCard {
            VStack(alignment: .leading, spacing: Runner.Spacing.snug) {
                HStack(alignment: .center, spacing: Runner.Spacing.snug) {
                    ProviderMark(provider: action.provider ?? "")

                    VStack(alignment: .leading, spacing: Runner.Spacing.xxsmall) {
                        Text(action.headline)
                            .font(Runner.Typography.smallMedium)
                            .foregroundStyle(Runner.Palette.foreground)
                            .lineLimit(1)

                        if let subtitle = action.subtitle {
                            Text(subtitle)
                                .font(Runner.Typography.caption)
                                .foregroundStyle(Runner.Palette.mutedForeground)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: Runner.Spacing.small)
                }

                if showsContext && !action.participants.isEmpty {
                    CardParticipantsSection(participants: action.participants)
                }

                if showsContext && !action.conversation.isEmpty {
                    CardConversationSection(messages: action.conversation, maxMessages: 12)
                }

                if action.hasDraft {
                    if showsContext && !action.conversation.isEmpty {
                        Text(SourceActionCopy.draftSectionTitle)
                            .font(Runner.Typography.captionMedium)
                            .foregroundStyle(Runner.Palette.mutedForeground)
                            .padding(.top, Runner.Spacing.xxsmall)
                    }

                    if action.provider == "gmail" {
                        TextField(SourceActionCopy.subjectTitle, text: $subject)
                            .font(Runner.Typography.smallMedium)
                            .foregroundStyle(Runner.Palette.foreground)
                            .padding(.horizontal, Runner.Spacing.snug)
                            .frame(minHeight: Runner.Layout.compactControlHeight)
                            .background(Runner.Palette.background, in: RoundedRectangle(cornerRadius: Runner.Radius.control, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: Runner.Radius.control, style: .continuous)
                                    .stroke(Runner.Palette.border, lineWidth: Runner.Stroke.hairline)
                            }
                            .accessibilityIdentifier("source-action-subject")
                    }

                    TextEditor(text: $draftText)
                        .font(Runner.Typography.small)
                        .foregroundStyle(Runner.Palette.foreground)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: action.provider == "gmail" ? 132 : 88)
                        .padding(Runner.Spacing.small)
                        .background(Runner.Palette.foreground3, in: RoundedRectangle(cornerRadius: Runner.Radius.control, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Runner.Radius.control, style: .continuous)
                                .stroke(Runner.Palette.border, lineWidth: Runner.Stroke.hairline)
                        }
                        .accessibilityIdentifier("source-action-reply-body")

                    if let sendError {
                        Label(sendError, systemImage: "exclamationmark.triangle")
                            .font(Runner.Typography.caption)
                            .foregroundStyle(Runner.Palette.destructiveText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Runner.Spacing.small) { actionButtons }
                    VStack(alignment: .leading, spacing: Runner.Spacing.small) { actionButtons }
                }
            }
            .padding(Runner.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    @ViewBuilder
    private var actionButtons: some View {
        if action.hasDraft && action.provider != "slack" {
            Button {
                copyDraft()
            } label: {
                Label(
                    didCopyDraft ? SourceActionCopy.copiedTitle : SourceActionCopy.copyTitle,
                    systemImage: didCopyDraft ? "checkmark" : "doc.on.doc"
                )
            }
            .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
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
            }
            .buttonStyle(RunnerButtonStyle(.primary, compact: true))
            .disabled(isSending || didSend || draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("source-action-send")
        }

        if hasOpenAction {
            Button {
                openSource()
            } label: {
                Label(
                    action.provider == "slack" && action.hasDraft ? "Copy reply and open Slack" : (action.openLabel ?? SourceActionCopy.openFallbackTitle),
                    systemImage: "arrow.up.forward.app.fill"
                )
            }
            .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
            .accessibilityIdentifier("source-action-open")
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
        if action.provider == "slack" && action.hasDraft { copyDraft() }
        if canComposeMessage, let handle = action.recipientHandle {
            messageComposeDraft = MessageComposeDraft(
                recipients: [handle],
                body: draftText
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
    static let sendEmailTitle = "Approve and send"
    static let postTitle = "Post"
    static let sentTitle = "Sent"
    static let confirmEmailTitle = "Send this email?"
    static let confirmPostTitle = "Post this message?"
    static let confirmationMessage = "This will send through your connected account."
}
