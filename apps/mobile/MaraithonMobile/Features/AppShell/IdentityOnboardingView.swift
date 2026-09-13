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
    @FocusState private var focusedField: Field?

    private enum Field {
        case name
        case phones
    }

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
            ScrollView {
                VStack(alignment: .leading, spacing: Runner.Spacing.large) {
                    header

                    VStack(alignment: .leading, spacing: Runner.Spacing.small) {
                        RunnerSectionLabel(IdentityOnboardingCopy.nameSection)
                        TextField(IdentityOnboardingCopy.namePlaceholder, text: $displayName)
                            .textContentType(.name)
                            .focused($focusedField, equals: .name)
                            .runnerField(isFocused: focusedField == .name)
                    }

                    if !prefill.emails.isEmpty {
                        VStack(alignment: .leading, spacing: Runner.Spacing.small) {
                            RunnerSectionLabel(IdentityOnboardingCopy.emailSection)
                            RunnerCard {
                                ForEach(prefill.emails.indices, id: \.self) { index in
                                    if index > 0 { RunnerHairline() }
                                    Text(prefill.emails[index])
                                        .font(Runner.Typography.small)
                                        .foregroundStyle(Runner.Palette.foreground)
                                        .runnerCardRow()
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: Runner.Spacing.small) {
                        RunnerSectionLabel(IdentityOnboardingCopy.phoneSection)
                        TextField(IdentityOnboardingCopy.phonePlaceholder, text: $phones)
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                            .focused($focusedField, equals: .phones)
                            .runnerField(isFocused: focusedField == .phones)
                        Text(IdentityOnboardingCopy.phoneFooter)
                            .font(Runner.Typography.caption)
                            .foregroundStyle(Runner.Palette.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Runner.Layout.pageInset)
                .padding(.top, Runner.Spacing.large)
                .padding(.bottom, Runner.Spacing.xlarge)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                confirmBar
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .runnerPage()
            .interactiveDismissDisabled(isSaving)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Runner.Spacing.tight) {
            MaraithonBrandMark()

            Text(IdentityOnboardingCopy.title)
                .font(Runner.Typography.pageTitle)
                .tracking(Runner.Typography.pageTitleTracking)
                .foregroundStyle(Runner.Palette.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text(IdentityOnboardingCopy.intro)
                .font(Runner.Typography.body)
                .foregroundStyle(Runner.Palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var confirmBar: some View {
        VStack(spacing: Runner.Spacing.small) {
            if let errorMessage {
                Text(errorMessage)
                    .font(Runner.Typography.small)
                    .foregroundStyle(Runner.Palette.destructiveText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(IdentityOnboardingCopy.confirmTitle) {
                confirm()
            }
            .buttonStyle(RunnerButtonStyle(.primary, fullWidth: true))
            .disabled(isSaving)
        }
        .padding(.horizontal, Runner.Layout.pageInset)
        .padding(.vertical, Runner.Spacing.tight)
        .background(Runner.Palette.background)
        .overlay(alignment: .top) { RunnerHairline() }
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
