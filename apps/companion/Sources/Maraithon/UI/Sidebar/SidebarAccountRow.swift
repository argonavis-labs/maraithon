import SwiftUI

/// Initials avatar, account email, and a quiet sign-out control, pinned to
/// the bottom of the sidebar. Sign out asks once because it drops the
/// device token and returns to the pairing screen.
struct SidebarAccountRow: View {
    let account: DeviceAuth.Account
    let signOut: () -> Void

    @State private var confirmingSignOut = false
    @State private var hoveringSignOut = false

    var body: some View {
        HStack(spacing: Tokens.Spacing.small) {
            Text(Self.initials(for: account.email))
                .font(Tokens.Typography.captionMedium)
                .foregroundStyle(Tokens.Palette.foreground80)
                .frame(width: Tokens.Layout.avatarSize, height: Tokens.Layout.avatarSize)
                .background(Tokens.Palette.foreground5, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(account.email)
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
            Button {
                confirmingSignOut = true
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    .labelStyle(.iconOnly)
                    .font(Tokens.Typography.navIcon)
                    .foregroundStyle(hoveringSignOut ? Tokens.Palette.foreground : Tokens.Palette.mutedForeground)
                    .frame(width: Tokens.Layout.avatarSize, height: Tokens.Layout.avatarSize)
                    .background(
                        hoveringSignOut ? Tokens.Palette.foreground5 : .clear,
                        in: RoundedRectangle(cornerRadius: Tokens.CornerRadius.control)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringSignOut = $0 }
            .help("Sign out of this Mac")
            .accessibilityLabel("Sign out")
            .confirmationDialog("Sign out of Maraithon on this Mac?", isPresented: $confirmingSignOut) {
                Button("Sign out", role: .destructive, action: signOut)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Mac sources stop syncing until you pair this device again.")
            }
        }
        .padding(.horizontal, Tokens.Spacing.xxsmall)
        .padding(.top, Tokens.Spacing.small + 1)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Tokens.Palette.border)
                .frame(height: Tokens.Stroke.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Signed in as \(account.email) on \(account.deviceName)")
    }

    /// `kent@runner.now` → `KR`: first letter of the mailbox and of the
    /// domain, matching the web account row.
    nonisolated static func initials(for email: String) -> String {
        let parts = email
            .split(whereSeparator: { "@.".contains($0) })
            .map { String($0) }
            .filter { !$0.isEmpty }
        let letters = parts.prefix(2).compactMap { $0.first.map { String($0).uppercased() } }
        return letters.isEmpty ? "?" : letters.joined()
    }
}
