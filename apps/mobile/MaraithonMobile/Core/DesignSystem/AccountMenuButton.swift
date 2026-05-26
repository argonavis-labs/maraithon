import SwiftData
import SwiftUI

struct AccountMenuButton: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SessionStore.self) private var sessionStore
    @State private var isConfirmingReset = false
    @State private var resetError: String?

    var body: some View {
        Menu {
            if let email = sessionStore.user?.email {
                Label(email, systemImage: "person.crop.circle")
            }

            Button(role: .destructive) {
                isConfirmingReset = true
            } label: {
                Label("Reset Demo Data", systemImage: "arrow.clockwise")
            }

            Button(role: .destructive) {
                Task { await sessionStore.signOut() }
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            Image(systemName: "person.crop.circle")
        }
        .accessibilityLabel("Account")
        .confirmationDialog(
            "Reset all demo data?",
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset Demo Data", role: .destructive) {
                resetDemoData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Todos, contacts, and chats will be replaced with the starter dataset.")
        }
        .alert(
            "Reset Failed",
            isPresented: Binding(
                get: { resetError != nil },
                set: { if !$0 { resetError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(resetError ?? "Try again.")
        }
    }

    private func resetDemoData() {
        do {
            try DataSeeder.resetDemoData(in: modelContext)
        } catch {
            resetError = error.localizedDescription
        }
    }
}
