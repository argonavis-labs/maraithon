import SwiftUI

struct ContactRow: View {
    let contact: CRMContact

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(contact.status.tint.opacity(0.18))
                .frame(width: 44, height: 44)
                .overlay {
                    Text(initials)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(contact.status.tint)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(contact.name)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                }

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack {
                    StatusPill(title: contact.status.title, tint: contact.status.tint)
                    StatusPill(title: careSummary.title, tint: careTint)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var careSummary: RelationshipCareSummary {
        RelationshipCareInsight.summary(for: contact)
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

    private var initials: String {
        contact.name
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
    }

    private var subtitle: String {
        let context = contact.company.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !context.isEmpty else { return careSummary.subtitle }
        return "\(context) - \(careSummary.subtitle)"
    }
}
