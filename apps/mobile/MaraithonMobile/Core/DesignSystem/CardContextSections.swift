import SwiftUI

/// Quoted excerpt of the source conversation a card is acting on.
struct CardConversationSection: View {
    let messages: [CardConversationMessage]
    var maxMessages = 6

    var body: some View {
        if messages.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(messages.suffix(maxMessages).enumerated()), id: \.offset) { _, message in
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(message.fromUser == true ? Color.accentColor.opacity(0.6) : Color(uiColor: .separator))
                            .frame(width: 2)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(message.speakerLabel)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Text(message.text)
                                .font(.caption)
                                .foregroundStyle(.primary)
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
            VStack(alignment: .leading, spacing: 3) {
                ForEach(groupedRows, id: \.label) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .leading)

                        Text(row.people)
                            .font(.caption)
                            .foregroundStyle(.primary)
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
