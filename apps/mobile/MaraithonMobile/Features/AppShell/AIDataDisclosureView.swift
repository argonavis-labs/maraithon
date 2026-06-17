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
                VStack(alignment: .leading, spacing: 24) {
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
                        .font(.subheadline)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 120)
            }
            .navigationTitle(AIDataDisclosureCopy.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                acceptBar
            }
        }
        .interactiveDismissDisabled(true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.tint)
            Text(AIDataDisclosureCopy.headlineTitle)
                .font(.title2.weight(.semibold))
            Text(AIDataDisclosureCopy.headlineBody)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func section(title: String, body: String, bullets: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !bullets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(bullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                            Text(bullet)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var acceptBar: some View {
        VStack(spacing: 8) {
            Button(action: onAccept) {
                Text(AIDataDisclosureCopy.acceptTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text(AIDataDisclosureCopy.acceptFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
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
        "Skip Chat and the AI-powered Today summaries — the rest of the app (Work, People, Stream) works without sending anything to OpenAI.",
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
