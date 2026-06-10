import MessageUI
import SwiftUI

/// Square provider badge used on draft cards and source action cards.
struct ProviderMark: View {
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
        case "calendar":
            return "calendar"
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

struct MessageComposeDraft: Identifiable {
    let id = UUID()
    let recipients: [String]
    let body: String
}

struct MessageComposeView: UIViewControllerRepresentable {
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
