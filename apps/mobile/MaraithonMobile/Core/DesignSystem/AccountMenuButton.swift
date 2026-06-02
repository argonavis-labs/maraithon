import SwiftData
import SwiftUI

struct AccountMenuButton: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SessionStore.self) private var sessionStore
    @State private var isConfirmingReset = false
    @State private var isShowingActivityLog = false
    @State private var resetError: String?

    var body: some View {
        Menu {
            if let email = sessionStore.user?.email {
                Label(email, systemImage: "person.crop.circle")
            }

            if sessionStore.user?.sessionToken != nil {
                Button {
                    isShowingActivityLog = true
                } label: {
                    Label(AccountMenuCopy.activityLogLabel, systemImage: "list.bullet.rectangle")
                }
            }

            if showsStarterDataReset {
                Button(role: .destructive) {
                    isConfirmingReset = true
                } label: {
                    Label(AccountMenuCopy.resetLocalWorkspaceLabel, systemImage: "arrow.clockwise")
                }
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
            AccountMenuCopy.resetLocalWorkspaceTitle,
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button(AccountMenuCopy.resetLocalWorkspaceLabel, role: .destructive) {
                resetStarterData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(AccountMenuCopy.resetLocalWorkspaceMessage)
        }
        .alert(
            AccountMenuCopy.resetFailedTitle,
            isPresented: Binding(
                get: { resetError != nil },
                set: { if !$0 { resetError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(resetError ?? AccountMenuCopy.resetFailedFallback)
        }
        .sheet(isPresented: $isShowingActivityLog) {
            TodoActivityLogView()
        }
    }

    private var showsStarterDataReset: Bool {
        #if DEBUG
        sessionStore.user?.sessionToken == nil
        #else
        false
        #endif
    }

    private func resetStarterData() {
        do {
            try DataSeeder.resetDemoData(in: modelContext)
        } catch {
            resetError = MobileErrorCopy.message(for: error)
        }
    }
}

enum AccountMenuCopy {
    static let activityLogLabel = "Activity Log"
    static let resetLocalWorkspaceLabel = "Reset Local Workspace"
    static let resetLocalWorkspaceTitle = "Reset local workspace?"
    static let resetLocalWorkspaceMessage =
        "This replaces the local preview work, people, and chats on this device. Your Maraithon account is not affected."
    static let resetFailedTitle = "Could Not Reset Workspace"
    static let resetFailedFallback = "Reset did not complete. Close and reopen Maraithon before resetting local workspace."

    static let resetVisibleStrings = [
        resetLocalWorkspaceLabel,
        resetLocalWorkspaceTitle,
        resetLocalWorkspaceMessage,
        resetFailedTitle,
        resetFailedFallback
    ]
}
