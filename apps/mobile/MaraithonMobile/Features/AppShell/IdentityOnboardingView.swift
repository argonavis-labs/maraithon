import SwiftUI

/// One-time identity confirmation: who the user is across channels, so
/// Maraithon can tell their own messages apart from people contacting them.
/// Prefilled from connected accounts and the user's own sent messages.
struct IdentityOnboardingView: View {
    let prefill: MobileAPIClient.IdentityResponse.Identity
    var onConfirmed: () -> Void

    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var phones: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let api = MobileAPIClient()

    init(
        prefill: MobileAPIClient.IdentityResponse.Identity,
        onConfirmed: @escaping () -> Void = {}
    ) {
        self.prefill = prefill
        self.onConfirmed = onConfirmed
        _displayName = State(initialValue: prefill.displayName ?? "")
        _phones = State(initialValue: prefill.phones.joined(separator: ", "))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(IdentityOnboardingCopy.intro)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section(IdentityOnboardingCopy.nameSection) {
                    TextField(IdentityOnboardingCopy.namePlaceholder, text: $displayName)
                        .textContentType(.name)
                }

                if !prefill.emails.isEmpty {
                    Section(IdentityOnboardingCopy.emailSection) {
                        ForEach(prefill.emails, id: \.self) { email in
                            Text(email)
                                .font(.subheadline)
                        }
                    }
                }

                Section {
                    TextField(IdentityOnboardingCopy.phonePlaceholder, text: $phones)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                } header: {
                    Text(IdentityOnboardingCopy.phoneSection)
                } footer: {
                    Text(IdentityOnboardingCopy.phoneFooter)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(IdentityOnboardingCopy.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(IdentityOnboardingCopy.confirmTitle) {
                        confirm()
                    }
                    .disabled(isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func confirm() {
        guard let sessionToken = sessionStore.user?.sessionToken else { return }
        isSaving = true
        errorMessage = nil

        let phoneList = phones
            .split(whereSeparator: { ",;\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        Task {
            defer { isSaving = false }

            do {
                _ = try await api.confirmIdentity(
                    sessionToken: sessionToken,
                    displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                    emails: prefill.emails,
                    phones: phoneList
                )
                onConfirmed()
                dismiss()
            } catch {
                errorMessage = IdentityOnboardingCopy.saveError
            }
        }
    }
}

enum IdentityOnboardingCopy {
    static let title = "Confirm who you are"
    static let intro =
        "Maraithon uses this to tell your own messages apart from people contacting you — especially in group chats."
    static let nameSection = "Your name"
    static let namePlaceholder = "Name"
    static let emailSection = "Your emails (from connected accounts)"
    static let phoneSection = "Your phone numbers"
    static let phonePlaceholder = "e.g. 416-555-0123, 647-555-0456"
    static let phoneFooter = "Detected from messages you've sent; correct or add as needed."
    static let confirmTitle = "Confirm"
    static let saveError = "Could not save. Check your connection and try again."
}
