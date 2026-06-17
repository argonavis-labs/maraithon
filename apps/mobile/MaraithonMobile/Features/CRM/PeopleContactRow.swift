import SwiftUI

struct PeopleContactRow: View {
    let context: PeopleContactContext
    let tab: PeopleFocusTab

    private var contact: CRMContact {
        context.contact
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(contact.status.tint.opacity(0.18))
                .frame(width: 44, height: 44)
                .overlay {
                    Text(initials)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(contact.status.tint)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(contact.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 8)
                }

                Text(context.signalLine(for: tab))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(context.contextLine(for: tab))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let action = suggestedAction {
                    Label(action, systemImage: "arrow.turn.up.right")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    ForEach(context.badges.prefix(3)) { badge in
                        StatusPill(title: badge.title, tint: badge.tint)
                    }
                }
            }
        }
        .padding(.vertical, 5)
    }

    private var suggestedAction: String? {
        guard tab == .suggested || tab == .all else { return nil }
        return context.suggestion?.suggestedAction?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
    }

    private var initials: String {
        contact.name
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
