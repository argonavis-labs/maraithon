import SwiftUI

enum MagicSigninCopy {
    static let sendCodeButton = "Send sign-in code"
    static let localCodeLabel = "One-time sign-in code"
    static let useLocalCodeButton = "Use this code"
    static let localCodeAccessibilityIdentifier = "one-time-sign-in-code"

    static var localCodeVisibleStrings: [String] {
        [sendCodeButton, localCodeLabel, useLocalCodeButton]
    }
}

/// Signed-out screen, styled like the Mac Connect page: brand mark, title,
/// supporting sentence, hairline fields, one ink primary action, quiet footer.
struct MagicSigninView: View {
    @Environment(SessionStore.self) private var sessionStore
    @State private var email = ""
    @State private var pastedCode = ""
    @FocusState private var focusedField: Field?

    private enum Field {
        case email
        case code
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Runner.Spacing.large) {
                    header

                    if let request = sessionStore.pendingMagicLink {
                        linkForm(for: request)
                    } else {
                        emailForm
                    }

                    if let errorMessage = sessionStore.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(Runner.Typography.small)
                            .foregroundStyle(Runner.Palette.destructiveText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("signin-error")
                    }
                }
                .padding(.horizontal, Runner.Spacing.large)
                .padding(.top, Runner.Spacing.xlarge * 2)
                .padding(.bottom, Runner.Spacing.xlarge)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { footer }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .runnerPage()
            .onAppear {
                focusedField = sessionStore.pendingMagicLink == nil ? .email : .code
            }
            .onChange(of: sessionStore.pendingMagicLink) { _, request in
                focusedField = request == nil ? .email : .code
            }
        }
    }

    private var header: some View {
        VStack(spacing: Runner.Spacing.tight) {
            MaraithonBrandMark()

            Text("Maraithon")
                .font(Runner.Typography.pageTitle)
                .tracking(Runner.Typography.pageTitleTracking)
                .foregroundStyle(Runner.Palette.foreground)
                .accessibilityAddTraits(.isHeader)

            Text("Enter your email and we'll send a one-time code. If this is your first time here, Maraithon creates your workspace automatically.")
                .font(Runner.Typography.body)
                .foregroundStyle(Runner.Palette.mutedForeground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .textSelection(.enabled)
    }

    private var emailForm: some View {
        VStack(spacing: Runner.Spacing.tight) {
            TextField("Work email", text: $email)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .submitLabel(.continue)
                .focused($focusedField, equals: .email)
                .onSubmit { submitEmail() }
                .runnerField(isFocused: focusedField == .email)

            Button {
                submitEmail()
            } label: {
                Label(MagicSigninCopy.sendCodeButton, systemImage: "paperplane.fill")
            }
            .buttonStyle(RunnerButtonStyle(.primary, fullWidth: true))
            .disabled(sessionStore.isBusy)
        }
    }

    private func linkForm(for request: MagicLinkRequest) -> some View {
        VStack(alignment: .leading, spacing: Runner.Spacing.medium) {
            VStack(alignment: .leading, spacing: Runner.Spacing.xsmall) {
                Text("Check your email")
                    .font(Runner.Typography.sectionTitle)
                    .foregroundStyle(Runner.Palette.foreground)

                Text("We sent a one-time code to \(request.email). Codes expire in 15 minutes.")
                    .font(Runner.Typography.small)
                    .foregroundStyle(Runner.Palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let oneTimeCode = request.developmentCode {
                RunnerCard {
                    VStack(alignment: .leading, spacing: Runner.Spacing.tight) {
                        Label(MagicSigninCopy.localCodeLabel, systemImage: "key.fill")
                            .font(Runner.Typography.smallMedium)
                            .foregroundStyle(Runner.Palette.foreground)

                        Text(oneTimeCode)
                            .font(Runner.Typography.sectionTitle.monospaced())
                            .foregroundStyle(Runner.Palette.mutedForeground)
                            .textSelection(.enabled)

                        Button {
                            consumeMagicLink(oneTimeCode)
                        } label: {
                            Label(MagicSigninCopy.useLocalCodeButton, systemImage: "checkmark.seal.fill")
                        }
                        .buttonStyle(RunnerButtonStyle(.secondary, fullWidth: true))
                        .disabled(sessionStore.isBusy)
                    }
                    .padding(Runner.Spacing.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier(MagicSigninCopy.localCodeAccessibilityIdentifier)
            }

            TextField("Enter sign-in code", text: $pastedCode)
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
                .textContentType(.oneTimeCode)
                .submitLabel(.continue)
                .focused($focusedField, equals: .code)
                .onSubmit { submitCode() }
                .runnerField(isFocused: focusedField == .code)

            Button {
                submitCode()
            } label: {
                Label("Continue", systemImage: "checkmark.seal.fill")
            }
            .buttonStyle(RunnerButtonStyle(.primary, fullWidth: true))
            .disabled(sessionStore.isBusy || pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Use another email") {
                pastedCode = ""
                sessionStore.cancelMagicLinkRequest()
                focusedField = .email
            }
            .buttonStyle(RunnerButtonStyle(.plain))
            .frame(maxWidth: .infinity)
        }
    }

    private var footer: some View {
        Text("Your chief of staff, wherever you work.")
            .font(Runner.Typography.caption)
            .foregroundStyle(Runner.Palette.mutedForeground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Runner.Spacing.medium)
            .background(Runner.Palette.background)
    }

    private func submitEmail() {
        Task {
            await sessionStore.requestMagicLink(email: email)
            focusedField = .code
        }
    }

    private func submitCode() {
        consumeMagicLink(pastedCode)
    }

    private func consumeMagicLink(_ linkOrToken: String) {
        Task {
            await sessionStore.consumeMagicLink(linkOrToken)
        }
    }
}

// MARK: - Shared onboarding chrome

/// The terracotta "m" mark the Mac and web apps use: a rounded square with a
/// white serif glyph, nudged up so the x-height letter sits optically centered.
struct MaraithonBrandMark: View {
    var size: CGFloat = 44

    var body: some View {
        Text("m")
            .font(Runner.Typography.brandMark)
            .foregroundStyle(.white)
            .padding(.bottom, Runner.Spacing.xsmall)
            .frame(width: size, height: size)
            .background(Runner.Palette.accent, in: RoundedRectangle(cornerRadius: Runner.Radius.mark, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Hairline text field: ground fill, 44pt tall, hairline border that turns
/// into the ring color while focused.
private struct RunnerFieldChrome: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            .font(Runner.Typography.body)
            .foregroundStyle(Runner.Palette.foreground)
            .padding(.horizontal, Runner.Spacing.tight)
            .frame(height: Runner.Layout.controlHeight)
            .background(Runner.Palette.background, in: RoundedRectangle(cornerRadius: Runner.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Runner.Radius.control, style: .continuous)
                    .stroke(
                        isFocused ? Runner.Palette.ring : Runner.Palette.border,
                        lineWidth: isFocused ? Runner.Stroke.control : Runner.Stroke.hairline
                    )
            }
    }
}

extension View {
    func runnerField(isFocused: Bool) -> some View {
        modifier(RunnerFieldChrome(isFocused: isFocused))
    }
}
