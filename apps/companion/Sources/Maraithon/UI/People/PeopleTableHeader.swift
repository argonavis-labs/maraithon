import SwiftUI

/// Column header band for the People table; widths shared with `PersonRow`.
struct PeopleTableHeader: View {
    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Text("Person")
                .padding(.horizontal, Tokens.Spacing.tight)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Channels")
                .padding(.horizontal, Tokens.Spacing.tight)
                .frame(width: Tokens.PeopleLayout.channelsColumn, alignment: .leading)
            Text("Last contact")
                .padding(.horizontal, Tokens.Spacing.tight)
                .frame(width: Tokens.PeopleLayout.contactColumn, alignment: .leading)
            Text("Active days")
                .padding(.horizontal, Tokens.Spacing.tight)
                .frame(width: Tokens.PeopleLayout.activeColumn, alignment: .trailing)
            Text("Messages")
                .padding(.horizontal, Tokens.Spacing.tight)
                .frame(width: Tokens.PeopleLayout.messagesColumn, alignment: .trailing)
        }
        .font(Tokens.Typography.caption)
        .foregroundStyle(Tokens.Palette.mutedForeground)
        .padding(.vertical, Tokens.Spacing.snug)
        .background(Tokens.Palette.foreground3, in: RoundedRectangle(cornerRadius: Tokens.CornerRadius.control - 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("People table header")
    }
}
