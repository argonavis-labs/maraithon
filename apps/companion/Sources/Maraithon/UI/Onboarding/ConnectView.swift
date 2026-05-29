import SwiftUI

/// First-run / signed-out screen. Mirrors Apple's standard onboarding
/// pattern (Mail.app, Calendar.app first-run): app glyph, title,
/// supporting sentence, single primary CTA, optional secondary affordance
/// below.
///
/// Layout invariants: vertically centered, max width
/// `Tokens.Layout.onboardingMaxWidth`, primary CTA is `.borderedProminent`
/// + `.keyboardShortcut(.defaultAction)`.
struct ConnectView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: Tokens.Spacing.large) {
            Spacer(minLength: 0)

            appGlyph

            VStack(spacing: Tokens.Spacing.small) {
                Text(ConnectCopy.title)
                    .font(.largeTitle.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(ConnectCopy.body)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: Tokens.Spacing.small) {
                Button {
                    env.deviceAuth.beginPairing()
                } label: {
                    Text(ConnectCopy.connectButton)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(ConnectCopy.title)

                if case .error(let message) = env.deviceAuth.state {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(StatusTone.error.color)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: 280)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.Spacing.xlarge)
        .padding(.vertical, Tokens.Spacing.xlarge)
        .frame(maxWidth: Tokens.Layout.onboardingMaxWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.default, value: env.deviceAuth.state)
        .onChange(of: env.deviceAuth.state) { _, newState in
            if case .signedIn = newState, env.onboarding.current == .connect {
                env.onboarding.advance()
            }
        }
        .onAppear {
            // Cover the relaunch case: DeviceAuth hydrates from Keychain
            // and transitions to .signedIn before this view is mounted,
            // so .onChange never fires. Check on appear too.
            if case .signedIn = env.deviceAuth.state,
               env.onboarding.current == .connect {
                env.onboarding.advance()
            }
        }
    }

    private var appGlyph: some View {
        Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
            .frame(width: Tokens.IconSize.large, height: Tokens.IconSize.large)
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
    }
}
