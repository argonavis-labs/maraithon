import MessageUI
import SwiftUI
import UIKit

/// Action card for a work item's source channel: shows the full suggested
/// wording with copy support and a one-tap path back into the source app.
struct SourceActionCardView: View {
    let action: TodoSourceAction

    @Environment(\.openURL) private var openURL
    @State private var messageComposeDraft: MessageComposeDraft?
    @State private var didCopyDraft = false

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

            if let draftText = action.draftText, action.hasDraft {
                Text(draftText)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
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
                    .buttonStyle(.borderedProminent)
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
    }

    private var canComposeMessage: Bool {
        action.prefersMessageCompose && MFMessageComposeViewController.canSendText()
    }

    private var hasOpenAction: Bool {
        action.openURL != nil || canComposeMessage
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
        guard let draftText = action.draftText else { return }
        UIPasteboard.general.string = draftText
        didCopyDraft = true

        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopyDraft = false
        }
    }
}

enum SourceActionCopy {
    static let copyTitle = "Copy draft"
    static let copiedTitle = "Copied"
    static let openFallbackTitle = "Open source"
}
