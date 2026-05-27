import SwiftUI

struct MagicSigninView: View {
    @Environment(SessionStore.self) private var sessionStore
    @State private var email = ""
    @State private var pastedCode = ""
    @State private var mode: AuthEntryMode = .signIn
    @FocusState private var focusedField: Field?

    private enum Field {
        case email
        case code
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header

                    if let request = sessionStore.pendingMagicLink {
                        linkForm(for: request)
                    } else {
                        emailForm
                    }

                    if let errorMessage = sessionStore.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("signin-error")
                    }
                }
                .padding(24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Maraithon")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                focusedField = sessionStore.pendingMagicLink == nil ? .email : .code
            }
            .onChange(of: sessionStore.pendingMagicLink) { _, request in
                focusedField = request == nil ? .email : .code
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "sparkles.square.filled.on.square")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            Text("Maraithon")
                .font(.largeTitle.bold())

            Text("Enter your email and we'll send a one-time code. New accounts are created automatically, matching the web app.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
    }

    private var emailForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Mode", selection: $mode) {
                ForEach(AuthEntryMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            TextField("Email", text: $email)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .submitLabel(.continue)
                .focused($focusedField, equals: .email)
                .onSubmit { submitEmail() }
                .padding(14)
                .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Button {
                submitEmail()
            } label: {
                Label(mode.actionTitle, systemImage: "paperplane.fill")
                    .frame(maxWidth: .infinity)
            }
            .appProminentGlassActionStyle()
            .controlSize(.large)
            .disabled(sessionStore.isBusy)
        }
    }

    private func linkForm(for request: MagicLinkRequest) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Check your email")
                .font(.headline)

            Text("We sent a one-time code to \(request.email). Codes expire in 15 minutes.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let developmentCode = request.developmentCode {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Development sign-in code", systemImage: "key.fill")
                        .font(.subheadline.weight(.semibold))

                    Text(developmentCode)
                        .font(.title3.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    Button {
                        consumeMagicLink(developmentCode)
                    } label: {
                        Label("Use Development Code", systemImage: "checkmark.seal.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .appGlassActionStyle()
                    .disabled(sessionStore.isBusy)
                }
                .padding(14)
                .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityIdentifier("development-sign-in-code")
            }

            TextField("Enter sign-in code", text: $pastedCode)
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
                .textContentType(.oneTimeCode)
                .submitLabel(.continue)
                .focused($focusedField, equals: .code)
                .onSubmit { submitCode() }
                .padding(14)
                .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack {
                Button("Use another email") {
                    pastedCode = ""
                    sessionStore.cancelMagicLinkRequest()
                    focusedField = .email
                }
                .buttonStyle(.borderless)

                Spacer()

                Button {
                    submitCode()
                } label: {
                    Label("Continue", systemImage: "checkmark.seal.fill")
                }
                .appProminentGlassActionStyle()
                .disabled(sessionStore.isBusy || pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
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
