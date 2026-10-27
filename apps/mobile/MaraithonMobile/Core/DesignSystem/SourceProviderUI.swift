import MessageUI
import SwiftUI

/// Small square provider mark used on rows, draft cards, and source action
/// cards: a hairline tile with the provider logo and no colored fill.
struct ProviderMark: View {
    let provider: String
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Runner.Radius.checkbox, style: .continuous)
                .fill(assetName == nil ? Runner.Palette.foreground5 : Runner.Palette.background)

            if let assetName {
                Image(assetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size - 6, height: size - 6)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: iconName)
                    .font(.system(size: size * 0.55, weight: .medium))
                    .foregroundStyle(Runner.Palette.foreground80)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: Runner.Radius.checkbox, style: .continuous)
                .stroke(Runner.Palette.border, lineWidth: Runner.Stroke.hairline)
        )
        .accessibilityHidden(true)
    }

    private var assetName: String? {
        switch provider {
        case "browser":
            return "ProviderChromeLogo"
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
            return "sparkles"
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
