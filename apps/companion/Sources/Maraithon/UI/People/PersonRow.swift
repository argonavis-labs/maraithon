import SwiftUI
import PeopleNetworkKit

/// One People table row: avatar, name and subtitle, channels, last contact,
/// active days, and message count. Clicking the row opens the person.
struct PersonRow: View {
    let person: PeopleNetworkData.Person
    let select: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(alignment: .center, spacing: 0) {
                HStack(spacing: Tokens.Spacing.tight) {
                    PersonAvatar(initials: person.initials, size: Tokens.PeopleLayout.avatarSize)
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xxsmall) {
                        Text(person.name)
                            .font(Tokens.Typography.bodyMedium)
                            .foregroundStyle(hovering ? Tokens.Palette.accent : Tokens.Palette.foreground)
                            .lineLimit(1)
                        if let subtitle = person.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(Tokens.Typography.caption)
                                .foregroundStyle(Tokens.Palette.mutedForeground)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, Tokens.Spacing.tight)
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(PeopleCopy.channels(person))
                    .font(Tokens.Typography.small)
                    .foregroundStyle(Tokens.Palette.foreground80)
                    .lineLimit(1)
                    .padding(.horizontal, Tokens.Spacing.tight)
                    .frame(width: Tokens.PeopleLayout.channelsColumn, alignment: .leading)

                Text(PeopleCopy.lastContact(person.lastAt))
                    .font(Tokens.Typography.small)
                    .foregroundStyle(Tokens.Palette.mutedForeground)
                    .help(PeopleCopy.absoluteContact(person.lastAt))
                    .padding(.horizontal, Tokens.Spacing.tight)
                    .frame(width: Tokens.PeopleLayout.contactColumn, alignment: .leading)

                Text("\(person.activeDays)")
                    .font(Tokens.Typography.small.monospacedDigit())
                    .foregroundStyle(Tokens.Palette.foreground80)
                    .padding(.horizontal, Tokens.Spacing.tight)
                    .frame(width: Tokens.PeopleLayout.activeColumn, alignment: .trailing)

                Text("\(person.messageCount)")
                    .font(Tokens.Typography.small.monospacedDigit())
                    .foregroundStyle(Tokens.Palette.mutedForeground)
                    .padding(.horizontal, Tokens.Spacing.tight)
                    .frame(width: Tokens.PeopleLayout.messagesColumn, alignment: .trailing)
            }
            .padding(.vertical, Tokens.Spacing.tight)
            .background(hovering ? Tokens.Palette.foreground3 : .clear)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Tokens.Palette.border)
                    .frame(height: Tokens.Stroke.hairline)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel("\(person.name), \(PeopleCopy.lastContact(person.lastAt))")
        .accessibilityHint("Opens this person")
    }
}

/// Initials chip used in People rows and the person header.
struct PersonAvatar: View {
    let initials: String
    let size: CGFloat

    var body: some View {
        Text(initials.isEmpty ? "?" : initials)
            .font(size > Tokens.PeopleLayout.avatarSize ? Tokens.Typography.bodySemibold : Tokens.Typography.captionMedium)
            .foregroundStyle(Tokens.Palette.foreground80)
            .frame(width: size, height: size)
            .background(Tokens.Palette.foreground5, in: Circle())
            .accessibilityHidden(true)
    }
}
