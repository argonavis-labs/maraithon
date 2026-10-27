import SwiftUI
import AssistantProgressKit

/// Quoted excerpt of the source conversation a card is acting on.
struct CardConversationSection: View {
    let messages: [CardConversationMessage]
    var maxMessages = 6
    var provider = ""

    var body: some View {
        if messages.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: Runner.Spacing.small) {
                ForEach(Array(messages.suffix(maxMessages).enumerated()), id: \.offset) { _, message in
                    HStack(alignment: .top, spacing: Runner.Spacing.small) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(message.fromUser == true ? Runner.Palette.accent : Runner.Palette.foreground10)
                            .frame(width: 2)

                        VStack(alignment: .leading, spacing: Runner.Spacing.xxsmall) {
                            HStack(alignment: .firstTextBaseline, spacing: Runner.Spacing.compact) {
                                Text(message.speakerLabel)
                                    .font(Runner.Typography.captionMedium)
                                    .foregroundStyle(Runner.Palette.foreground80)

                                if let timestamp = message.timestampLabel {
                                    Text(timestamp)
                                        .font(Runner.Typography.caption)
                                        .foregroundStyle(Runner.Palette.mutedForeground)
                                }
                            }

                            ChannelMessageText(message.text, provider: provider)
                                .font(Runner.Typography.small)
                                .foregroundStyle(Runner.Palette.foreground)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

/// Everyone involved on a card, with their channel role preserved.
struct CardParticipantsSection: View {
    let participants: [CardParticipant]

    private static let roleOrder = ["from", "to", "cc", "bcc"]

    var body: some View {
        if participants.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: Runner.Spacing.xsmall) {
                ForEach(groupedRows, id: \.label) { row in
                    HStack(alignment: .firstTextBaseline, spacing: Runner.Spacing.compact) {
                        Text(row.label)
                            .font(Runner.Typography.captionMedium)
                            .foregroundStyle(Runner.Palette.mutedForeground)
                            .frame(width: 34, alignment: .leading)

                        Text(row.people)
                            .font(Runner.Typography.small)
                            .foregroundStyle(Runner.Palette.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var groupedRows: [(label: String, people: String)] {
        let grouped = Dictionary(grouping: participants) { $0.role ?? "participant" }

        var rows: [(label: String, people: String)] = []

        for role in Self.roleOrder {
            if let people = grouped[role], !people.isEmpty {
                rows.append((
                    label: people.first?.roleLabel ?? role.capitalized,
                    people: people.map(\.detailedLabel).joined(separator: ", ")
                ))
            }
        }

        let others = participants.filter { !Self.roleOrder.contains($0.role ?? "participant") }
        if !others.isEmpty {
            rows.append((label: "With", people: others.map(\.detailedLabel).joined(separator: ", ")))
        }

        return rows
    }
}
