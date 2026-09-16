/// One native assistant form for both clients; all changes use the authenticated server settings.
import SwiftUI

public struct AssistantSettingsView: View {
    private let webURL: URL?
    private let request: AssistantSettings.Transport
    @State private var settings: AssistantSettings.Settings?
    @State private var identity: [String: AssistantSettings.Value] = [:]
    @State private var preferences: [String: AssistantSettings.Value] = [:]
    @State private var accountID = 0
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?

    public init(webURL: URL?, request: @escaping AssistantSettings.Transport) {
        self.webURL = webURL
        self.request = request
    }

    public var body: some View {
        Form {
            if let settings {
                if settings.enabled {
                    identityForm(settings)
                    preferencesForm(settings)
                } else {
                    Text("Delegation is not available for this account yet.")
                }
            }
            if busy { ProgressView("Updating assistant settings") }
            if let error {
                Section {
                    Text(error).foregroundStyle(.red)
                    Button("Reload settings") { Task { await load() } }.disabled(busy)
                }
            }
            if let notice { Text(notice).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .navigationTitle("Assistant settings")
        .task { await load() }
    }

    @ViewBuilder private func identityForm(_ settings: AssistantSettings.Settings) -> some View {
        Section("Your assistant") {
            if let webURL { Link("Connect your assistant's Google account", destination: webURL) }
            Picker("Google account", selection: $accountID) {
                Text("Choose an account").tag(0)
                ForEach(settings.accounts ?? []) { Text($0.label).tag($0.id) }
            }
            Button("Check addresses") { Task { await load(account: accountID) } }
                .disabled(accountID == 0)
            if let problem = settings.error { Text(problem).foregroundStyle(.red) }
            if accountID == settings.selectedAccount, let addresses = settings.aliases, !addresses.isEmpty {
                TextField("Assistant name", text: identityText("display_name"))
                Picker("Email address", selection: identityText("gmail_send_as_email")) {
                    Text("Choose an address").tag("")
                    ForEach(addresses, id: \.email) { Text($0.email).tag($0.email) }
                }
                Picker("Email identity", selection: identityText("gmail_mode")) {
                    Text("Assistant's own account").tag("account")
                    Text("Verified alias on my account").tag("alias")
                }
                TextField("Slack name", text: identityText("slack_username"))
                TextField("Slack icon URL", text: identityText("slack_icon_url"))
                TextField("Signature override", text: identityText("signature_text"), axis: .vertical)
                Text("Leave the signature override blank to use the mailbox signature.")
                    .font(.footnote).foregroundStyle(.secondary)
                TextField("Disclosure line", text: identityText("disclosure_line"), axis: .vertical)
                Toggle("Disclose that the assistant is AI", isOn: identityBool("disclose_ai"))
                Toggle("Cc me on the first email", isOn: identityBool("cc_user_on_first_send"))
                Button("Save assistant") { Task { await saveIdentity() } }
            }
        }.disabled(busy)
    }

    @ViewBuilder private func preferencesForm(_ settings: AssistantSettings.Settings) -> some View {
        Section("Scheduling and follow-ups") {
            if let accounts = settings.calendarAccounts {
                Picker("Book meetings on", selection: bookingAccount) {
                    Text("Task's Google account").tag(0)
                    ForEach(accounts) { Text($0.label).tag($0.id) }
                }
                Text("Also check for conflicts").font(.headline)
                ForEach(accounts) { account in
                    Toggle(account.label, isOn: preferenceSelection("calendar_account_ids", account.id))
                }
                Text("Checks each account's primary calendar, including the booking account.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let zones = settings.timezones {
                Picker("Timezone", selection: preferenceText("timezone")) {
                    ForEach(zones, id: \.value) { Text($0.label).tag($0.value) }
                }
            } else {
                LabeledContent("Timezone", value: preferences["timezone"]?.string ?? "")
            }
            ForEach(Array(["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"].enumerated()), id: \.offset) { day, label in
                Toggle(label, isOn: preferenceSelection("work_days", day + 1))
            }
            TextField("Start of day (HH:mm)", text: preferenceText("work_start"))
            TextField("End of day (HH:mm)", text: preferenceText("work_end"))
            ForEach(settings.numericPreferences ?? [], id: \.key) { field in
                Stepper(value: preferenceNumber(field.key), in: field.min...field.max) {
                    LabeledContent(field.label, value: "\(preferences[field.key]?.integer ?? 0)")
                }
            }
            TextField("Video link", text: preferenceText("video_link"))
            Toggle("Suggest tasks to delegate", isOn: preferenceBool("proposals_enabled"))
            Button("Save preferences") { Task { await savePreferences() } }
        }.disabled(busy)
    }

    private func identityText(_ key: String) -> Binding<String> {
        Binding(get: { identity[key]?.string ?? "" }, set: { identity[key] = .string($0) })
    }
    private func identityBool(_ key: String) -> Binding<Bool> {
        Binding(get: { identity[key]?.bool ?? false }, set: { identity[key] = .bool($0) })
    }
    private func preferenceText(_ key: String) -> Binding<String> {
        Binding(get: { preferences[key]?.string ?? "" }, set: { preferences[key] = .string($0) })
    }
    private func preferenceBool(_ key: String) -> Binding<Bool> {
        Binding(get: { preferences[key]?.bool ?? false }, set: { preferences[key] = .bool($0) })
    }
    private func preferenceNumber(_ key: String) -> Binding<Int> {
        Binding(get: { preferences[key]?.integer ?? 0 }, set: { preferences[key] = .integer($0) })
    }
    private var bookingAccount: Binding<Int> {
        Binding(get: { preferences["booking_calendar_account_id"]?.integer ?? 0 }, set: {
            preferences["booking_calendar_account_id"] = $0 == 0 ? .null : .integer($0)
        })
    }
    private func preferenceSelection(_ key: String, _ value: Int) -> Binding<Bool> {
        Binding(get: { preferences[key]?.integers.contains(value) ?? false }, set: { enabled in
            var selected = Set(preferences[key]?.integers ?? [])
            if enabled { selected.insert(value) } else { selected.remove(value) }
            preferences[key] = .integers(selected.sorted())
        })
    }

    @MainActor private func load(account: Int? = nil) async {
        await perform(path: "delegation-settings" + (account.map { "?assistant_account=\($0)" } ?? ""))
    }
    @MainActor private func saveIdentity() async {
        var fields = identity
        fields["gmail_connected_account_id"] = .integer(accountID)
        await perform(path: "delegation-settings/identity", fields: fields)
    }
    @MainActor private func savePreferences() async {
        let keys = ["timezone", "work_days", "work_start", "work_end", "video_link", "proposals_enabled"]
            + (settings?.numericPreferences ?? []).map(\.key)
            + (settings?.calendarAccounts == nil ? [] : ["booking_calendar_account_id", "calendar_account_ids"])
        await perform(path: "delegation-settings/preferences", fields: preferences.filter { keys.contains($0.key) })
    }
    @MainActor private func perform(path: String, fields: [String: AssistantSettings.Value]? = nil) async {
        guard !busy else { return }
        busy = true; error = nil; notice = nil
        defer { busy = false }
        do {
            let value = try await request(path, fields).settings
            settings = value
            if !path.hasSuffix("/preferences") {
                accountID = value.selectedAccount ?? 0
                identity = value.identity ?? [:]
                if identity["disclosure_line"] == nil {
                    identity["disclosure_line"] = .string("I'm an AI assistant handling scheduling and follow-ups.")
                }
            }
            if !path.hasSuffix("/identity") { preferences = value.preferences ?? [:] }
            if fields != nil { notice = path.hasSuffix("/identity") ? "Assistant saved." : "Preferences saved." }
        } catch { self.error = error.localizedDescription }
    }
}
