import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(SessionStore.self) private var sessionStore
    @State private var identity: MobileAPIClient.IdentityResponse.Identity?
    @State private var schedule: MobileAPIClient.MorningSchedule?
    @State private var isEditingIdentity = false
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if let email = sessionStore.user?.email {
                        LabeledContent("Email", value: email)
                    }
                    Button {
                        isEditingIdentity = true
                    } label: {
                        Label("About you", systemImage: "person.crop.circle")
                    }
                    .disabled(identity == nil)
                }
                Section("Morning brief") {
                    if let schedule {
                        LabeledContent("Refresh", value: schedule.displayTime)
                        LabeledContent("Time zone", value: schedule.timezoneLabel)
                        if !schedule.configured {
                            Text("Morning briefing is not configured.").foregroundStyle(.secondary)
                        }
                    } else {
                        Text(isLoading ? "Loading schedule…" : "Schedule is unavailable.").foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        Label("Notifications & permissions", systemImage: "bell")
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.secondary)
                        Button("Retry") { Task { await load() } }
                    }
                }
                Section { LabeledContent("Version", value: version) }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
            .sheet(isPresented: $isEditingIdentity) {
                if let identity {
                    IdentityOnboardingView(prefill: identity) {
                        isEditingIdentity = false
                        Task { await load() }
                    }
                }
            }
        }
    }

    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "\(version) (\(build))"
    }

    private func load() async {
        guard let token = sessionStore.user?.sessionToken else {
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            async let identity = MobileAPIClient().getIdentity(sessionToken: token)
            async let briefs = MobileAPIClient().loadDailyBriefs(sessionToken: token, limit: 1)
            let results = try await (identity, briefs)
            self.identity = results.0
            schedule = results.1.morningSchedule
            errorMessage = nil
        } catch {
            errorMessage = MobileErrorCopy.message(for: error)
        }
    }
}
