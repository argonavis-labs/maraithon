import SwiftUI

/// First-run / signed-out screen, styled like the web welcome page: brand
/// mark, title, supporting sentence, one primary action, and a quiet footer.
///
/// Layout invariants: vertically centered, max width
/// `Tokens.Layout.onboardingMaxWidth`, primary CTA is the workspace primary
/// button + `.keyboardShortcut(.defaultAction)`.
struct ConnectView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: Tokens.Spacing.large) {
            Spacer(minLength: 0)

            appGlyph

            VStack(spacing: Tokens.Spacing.small) {
                Text(env.deviceAuth.hasStoredSession ? "Reconnect to Maraithon" : ConnectCopy.title)
                    .font(Tokens.Typography.pageTitle)
                    .tracking(Tokens.Typography.pageTitleTracking)
                    .foregroundStyle(Tokens.Palette.foreground)
                    .multilineTextAlignment(.center)

                Text(env.deviceAuth.hasStoredSession ? "This Mac is already paired. Reconnect to continue." : ConnectCopy.body)
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.mutedForeground)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: Tokens.Spacing.small) {
                Button {
                    env.deviceAuth.beginPairing()
                } label: {
                    Text(env.deviceAuth.hasStoredSession ? "Reconnect" : ConnectCopy.connectButton)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RunnerButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(env.deviceAuth.state == .connecting)
                .accessibilityLabel(env.deviceAuth.hasStoredSession ? "Reconnect to Maraithon" : ConnectCopy.title)

                if env.deviceAuth.state == .connecting { ProgressView("Reconnecting") }

                if case .awaitingApproval = env.deviceAuth.state {
                    Text("Sign-in opens in your browser.")
                        .font(Tokens.Typography.small)
                        .foregroundStyle(Tokens.Palette.mutedForeground)
                        .transition(.opacity)
                }

                if case .error(let message) = env.deviceAuth.state {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(Tokens.Typography.small)
                        .foregroundStyle(Tokens.Palette.destructiveText)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: 280)

            Spacer(minLength: 0)

            Text("Your chief of staff, wherever you work.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.mutedForeground)
        }
        .padding(.horizontal, Tokens.Spacing.xlarge)
        .padding(.vertical, Tokens.Spacing.xlarge)
        .frame(maxWidth: Tokens.Layout.onboardingMaxWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Palette.background)
        .animation(.default, value: env.deviceAuth.state)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, case .error = env.deviceAuth.state {
                Task { await env.deviceAuth.restoreSession() }
            }
        }
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
        Text("m")
            .font(Tokens.Typography.brandMarkLarge)
            .foregroundStyle(.white)
            .padding(.bottom, Tokens.Spacing.compact)
            .frame(width: Tokens.IconSize.large, height: Tokens.IconSize.large)
            .background(Tokens.Palette.accent, in: RoundedRectangle(cornerRadius: Tokens.CornerRadius.medium))
            .accessibilityHidden(true)
    }
}
