import SwiftUI

struct PeopleContactRow: View {
    let context: PeopleContactContext
    let tab: PeopleFocusTab

    private var contact: CRMContact {
        context.contact
    }

    var body: some View {
        HStack(alignment: .top, spacing: Runner.Spacing.tight) {
            PeopleAvatar(initials: PeopleAvatar.initials(for: contact.name))

            VStack(alignment: .leading, spacing: Runner.Spacing.xsmall) {
                Text(contact.name)
                    .font(Runner.Typography.bodyMedium)
                    .foregroundStyle(Runner.Palette.foreground)
                    .lineLimit(1)

                Text(context.signalLine(for: tab))
                    .font(Runner.Typography.small)
                    .foregroundStyle(Runner.Palette.foreground80)
                    .lineLimit(2)

                Text(context.contextLine(for: tab))
                    .font(Runner.Typography.caption)
                    .foregroundStyle(Runner.Palette.mutedForeground)
                    .lineLimit(1)

                if let action = suggestedAction {
                    Label(action, systemImage: "arrow.turn.up.right")
                        .font(Runner.Typography.caption)
                        .foregroundStyle(Runner.Palette.accent)
                        .lineLimit(2)
                }

                HStack(spacing: Runner.Spacing.compact) {
                    ForEach(context.badges.prefix(3)) { badge in
                        StatusPill(title: badge.title, tint: badge.tint)
                    }
                }
                .padding(.top, Runner.Spacing.xxsmall)
            }
        }
        .padding(.vertical, Runner.Spacing.xsmall)
    }

    private var suggestedAction: String? {
        guard tab == .suggested || tab == .all else { return nil }
        return context.suggestion?.suggestedAction?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
