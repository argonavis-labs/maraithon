import SwiftUI

/// First-launch disclosure explaining that Maraithon sends user content to a
/// third-party AI provider (OpenAI) so it can answer chat questions and run
/// the agent features. Apple App Review (Guidelines 5.1.1(i) / 5.1.2(i))
/// requires the app to disclose what is sent, identify the recipient, and
/// obtain explicit consent before any data leaves the device. The TabView
/// is gated on this consent so the requirement is satisfied before any AI
/// call is possible.
struct AIDataDisclosureView: View {
    var onAccept: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Runner.Spacing.large) {
                    header

                    section(
                        title: AIDataDisclosureCopy.whatSendTitle,
                        body: AIDataDisclosureCopy.whatSendBody,
                        bullets: AIDataDisclosureCopy.whatSendBullets
                    )

                    section(
                        title: AIDataDisclosureCopy.whoTitle,
                        body: AIDataDisclosureCopy.whoBody,
                        bullets: []
                    )

                    section(
                        title: AIDataDisclosureCopy.controlTitle,
                        body: AIDataDisclosureCopy.controlBody,
                        bullets: AIDataDisclosureCopy.controlBullets
                    )

                    Link(AIDataDisclosureCopy.privacyLinkTitle,
                         destination: URL(string: AIDataDisclosureCopy.privacyURL)!)
                        .font(Runner.Typography.smallMedium)
                        .foregroundStyle(Runner.Palette.accent)
                        .padding(.top, Runner.Spacing.xsmall)
                }
                .padding(.horizontal, Runner.Layout.pageInset)
                .padding(.top, Runner.Spacing.large)
                .padding(.bottom, Runner.Spacing.xlarge)
            }
            .safeAreaInset(edge: .bottom) {
                acceptBar
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .runnerPage()
        }
        .interactiveDismissDisabled(true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Runner.Spacing.tight) {
            MaraithonBrandMark()

            VStack(alignment: .leading, spacing: Runner.Spacing.compact) {
                Text(AIDataDisclosureCopy.navigationTitle)
                    .font(Runner.Typography.caption)
                    .foregroundStyle(Runner.Palette.mutedForeground)

                Text(AIDataDisclosureCopy.headlineTitle)
                    .font(Runner.Typography.pageTitle)
                    .tracking(Runner.Typography.pageTitleTracking)
                    .foregroundStyle(Runner.Palette.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }

            Text(AIDataDisclosureCopy.headlineBody)
                .font(Runner.Typography.body)
                .foregroundStyle(Runner.Palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section(title: String, body: String, bullets: [String]) -> some View {
        VStack(alignment: .leading, spacing: Runner.Spacing.small) {
            Text(title)
                .font(Runner.Typography.bodySemibold)
                .foregroundStyle(Runner.Palette.foreground)
                .accessibilityAddTraits(.isHeader)

            Text(body)
                .font(Runner.Typography.body)
                .foregroundStyle(Runner.Palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)

            if !bullets.isEmpty {
                RunnerCard {
                    ForEach(bullets.indices, id: \.self) { index in
                        if index > 0 { RunnerHairline() }
                        Text(bullets[index])
                            .font(Runner.Typography.small)
                            .foregroundStyle(Runner.Palette.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                            .runnerCardRow()
                    }
                }
                .padding(.top, Runner.Spacing.xsmall)
            }
        }
    }

    private var acceptBar: some View {
        VStack(spacing: Runner.Spacing.small) {
            Button(action: onAccept) {
                Text(AIDataDisclosureCopy.acceptTitle)
            }
            .buttonStyle(RunnerButtonStyle(.primary, fullWidth: true))

            Text(AIDataDisclosureCopy.acceptFooter)
                .font(Runner.Typography.caption)
                .foregroundStyle(Runner.Palette.mutedForeground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Runner.Layout.pageInset)
        .padding(.vertical, Runner.Spacing.tight)
        .background(Runner.Palette.background)
        .overlay(alignment: .top) { RunnerHairline() }
    }
}

enum AIDataDisclosureCopy {
    static let navigationTitle = "Before you start"
    static let headlineTitle = "Maraithon uses AI to help you"
    static let headlineBody =
        "Some Maraithon features send your content to a third-party AI provider so it can answer your questions and draft on your behalf. We want you to know exactly what is sent and who receives it before you turn it on."

    static let whatSendTitle = "What we send"
    static let whatSendBody =
        "When you use Chat or any AI-powered feature, we send the text you type along with the context required to answer it:"
    static let whatSendBullets = [
        "Your chat messages and the conversation history of the thread you are in.",
        "The work items, notes, contacts, and goals you reference so the answer is relevant.",
        "Your name and the date/time, so replies are personal and timely.",
    ]

    static let whoTitle = "Who receives it"
    static let whoBody =
        "We send this content to OpenAI, which provides the large-language-model inference that powers Maraithon's AI features. OpenAI processes the request, returns an answer, and is contractually bound not to use your content to train its models. Your data is not shared with any other third party for AI processing."

    static let controlTitle = "You stay in control"
    static let controlBody =
        "You only need to share data when you actively use an AI feature. You can:"
    static let controlBullets = [
        "You can use your Todos list without opening Chat or generating an AI summary.",
        "Delete a chat thread at any time to remove its history from Maraithon.",
        "Delete your account in Settings to wipe all your data, including anything previously sent for AI processing.",
    ]

    static let privacyLinkTitle = "Read the full privacy policy"
    static let privacyURL = "https://maraithon.com/privacy"

    static let acceptTitle = "I understand — continue"
    static let acceptFooter =
        "By continuing you agree that AI features may send the content above to OpenAI."
}

#Preview {
    AIDataDisclosureView {
        // no-op preview
    }
}
