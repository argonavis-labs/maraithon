import SwiftUI
import PeopleNetworkKit

/// One People row: avatar, name and subtitle, then channels, last contact,
/// and activity counts on a second line. Tapping opens the person page.
struct PeopleNetworkRow: View {
    let person: PeopleNetworkData.Person

    private var channels: String { PeopleNetworkCopy.channels(person) }
    private var lastContact: String { PeopleNetworkCopy.lastContact(person.lastAt) }
    private var activity: String { PeopleNetworkCopy.activity(person) }

    var body: some View {
        VStack(alignment: .leading, spacing: Runner.Spacing.compact) {
            HStack(spacing: Runner.Spacing.tight) {
                PeopleAvatar(initials: person.initials)
                VStack(alignment: .leading, spacing: Runner.Spacing.xxsmall) {
                    Text(person.name)
                        .font(Runner.Typography.bodyMedium)
                        .foregroundStyle(Runner.Palette.foreground)
                        .lineLimit(1)
                    if let subtitle = person.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(Runner.Typography.caption)
                            .foregroundStyle(Runner.Palette.mutedForeground)
                            .lineLimit(1)
                    }
                }
            }

            HStack(spacing: Runner.Spacing.compact) {
                if !channels.isEmpty {
                    Text(channels)
                        .font(Runner.Typography.small)
                        .foregroundStyle(Runner.Palette.foreground80)
                        .lineLimit(1)
                    Text("·")
                        .font(Runner.Typography.small)
                        .foregroundStyle(Runner.Palette.mutedForeground)
                }
                Text(lastContact)
                    .font(Runner.Typography.small)
                    .foregroundStyle(Runner.Palette.mutedForeground)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: Runner.Spacing.small)
                Text(activity)
                    .font(Runner.Typography.caption.monospacedDigit())
                    .foregroundStyle(Runner.Palette.mutedForeground)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .padding(.leading, Runner.Layout.avatarSize + Runner.Spacing.tight)
        }
        .padding(.vertical, Runner.Spacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens this person")
    }

    private var accessibilityText: String {
        var parts = [person.name]
        if let subtitle = person.subtitle, !subtitle.isEmpty { parts.append(subtitle) }
        if !channels.isEmpty { parts.append(channels) }
        parts.append(lastContact)
        parts.append(activity)
        return parts.joined(separator: ", ")
    }
}
