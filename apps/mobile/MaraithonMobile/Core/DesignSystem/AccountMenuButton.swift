import SwiftData
import SwiftUI

struct AccountMenuButton: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SessionStore.self) private var sessionStore
    @State private var isConfirmingReset = false
    @State private var isShowingActivityLog = false
    @State private var isShowingGoals = false
    @State private var isShowingSettings = false
    @State private var resetError: String?

    var body: some View {
        Menu {
            if let email = sessionStore.user?.email {
                Label(email, systemImage: "person.crop.circle")
            }

            Button {
                isShowingSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }

            if sessionStore.user?.sessionToken != nil {
                Button {
                    isShowingGoals = true
                } label: {
                    Label(AccountMenuCopy.goalsLabel, systemImage: "target")
                }
                .accessibilityIdentifier("profile-goals-button")

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
            AccountInitialsMark(email: sessionStore.user?.email)
        }
        .accessibilityLabel("Account and settings")
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
        .sheet(isPresented: $isShowingGoals) {
            GoalsProfileView()
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
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

/// 28pt initials circle for the signed-in account, on the subtle ink wash the
/// workspace uses for avatars. Falls back to a person glyph when signed out.
private struct AccountInitialsMark: View {
    let email: String?

    var body: some View {
        ZStack {
            Circle()
                .fill(Runner.Palette.foreground5)
            Circle()
                .stroke(Runner.Palette.border, lineWidth: Runner.Stroke.hairline)
            if let initials = Self.initials(from: email) {
                Text(initials)
                    .font(Runner.Typography.captionMedium)
                    .foregroundStyle(Runner.Palette.foreground)
            } else {
                Image(systemName: "person")
                    .font(Runner.Typography.caption)
                    .foregroundStyle(Runner.Palette.mutedForeground)
            }
        }
        .frame(width: 28, height: 28)
    }

    /// "kent.fenwick@…" → "KF", "kent@…" → "K".
    static func initials(from email: String?) -> String? {
        guard let email else { return nil }
        let local = email.split(separator: "@").first.map(String.init) ?? email
        let parts = local.split(whereSeparator: { ".-_+".contains($0) })
        let letters = parts.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }
        guard !letters.isEmpty else { return nil }
        return letters.joined()
    }
}

enum AccountMenuCopy {
    static let goalsLabel = "Goals"
    static let activityLogLabel = "Activity Log"
    static let resetLocalWorkspaceLabel = "Reset Local Workspace"
    static let resetLocalWorkspaceTitle = "Reset local workspace?"
    static let resetLocalWorkspaceMessage =
        "This replaces the local preview work, people, and chats on this device. Your Maraithon account is not affected."
    static let resetFailedTitle = "Could Not Reset Workspace"
    static let resetFailedFallback = "Reset did not complete. Close and reopen Maraithon before resetting local workspace."

    static let resetVisibleStrings = [
        goalsLabel,
        resetLocalWorkspaceLabel,
        resetLocalWorkspaceTitle,
        resetLocalWorkspaceMessage,
        resetFailedTitle,
        resetFailedFallback
    ]
}
