/// Mailbox and source categories are saved to the signed-in user's server account.
import SwiftUI

public struct AccountCategoriesView: View {
    public struct Response: Decodable, Sendable {
        public let accounts: [Account]
    }
    public struct Account: Decodable, Identifiable, Sendable {
        public let id: Int
        public let label: String
        public let provider: String
        public let category: String
    }
    private let request: @MainActor (Int?, String?) async throws -> Response
    @State private var accounts: [Account] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var error: String?

    public init(request: @escaping @MainActor (Int?, String?) async throws -> Response) {
        self.request = request
    }

    public var body: some View {
        Form {
            Section {
                Text("Choose which accounts belong to Personal or Work. Unassigned accounts appear under All.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if isLoading {
                ProgressView("Loading accounts")
            } else if accounts.isEmpty && error == nil {
                Text("No connected accounts yet.").foregroundStyle(.secondary)
            }
            Section("Accounts") {
                ForEach(accounts) { account in
                    Picker(account.label, selection: Binding(
                        get: { account.category },
                        set: { category in Task { await save(account.id, category) } }
                    )) {
                        Text("Unassigned").tag("unassigned")
                        Text("Personal").tag("personal")
                        Text("Work").tag("work")
                    }
                    .disabled(isSaving)
                }
            }
            if let error {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry") { Task { await load() } }
                }
            }
            if isSaving { ProgressView("Saving category") }
        }
        .formStyle(.grouped)
        .navigationTitle("Account settings")
        .task { await load() }
    }

    @MainActor private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            accounts = try await request(nil, nil).accounts
            error = nil
        } catch {
            self.error = "Could not load account settings. Try again."
        }
    }

    @MainActor private func save(_ id: Int, _ category: String) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            accounts = try await request(id, category).accounts
            error = nil
        } catch {
            self.error = "The category was not saved. Try again."
        }
    }
}
