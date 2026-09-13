import SwiftUI

struct ContactRow: View {
    let contact: CRMContact

    var body: some View {
        HStack(spacing: Runner.Spacing.tight) {
            PeopleAvatar(initials: PeopleAvatar.initials(for: contact.name))

            VStack(alignment: .leading, spacing: Runner.Spacing.xsmall) {
                Text(contact.name)
                    .font(Runner.Typography.bodyMedium)
                    .foregroundStyle(Runner.Palette.foreground)
                    .lineLimit(1)

                Text(subtitle)
                    .font(Runner.Typography.caption)
                    .foregroundStyle(Runner.Palette.mutedForeground)
                    .lineLimit(1)

                HStack(spacing: Runner.Spacing.compact) {
                    StatusPill(title: contact.status.title, tint: contact.status.tint)
                    StatusPill(title: careSummary.title, tint: careTint)
                }
            }
        }
        .padding(.vertical, Runner.Spacing.xsmall)
    }

    private var careSummary: RelationshipCareSummary {
        RelationshipCareSignal.summary(for: contact)
    }

    private var careTint: Color {
        switch careSummary.level {
        case .archived: .secondary
        case .warm: .green
        case .new: .indigo
        case .due: .orange
        case .needsCare: .red
        }
    }

    private var subtitle: String {
        let context = contact.company.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !context.isEmpty else { return careSummary.subtitle }
        return "\(context) - \(careSummary.subtitle)"
    }
}
