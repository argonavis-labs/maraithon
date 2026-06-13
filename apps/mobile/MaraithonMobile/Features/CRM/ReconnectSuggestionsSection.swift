import SwiftUI

/// The intelligent hero of the People tab: a ranked list of people the user
/// should reconnect with right now, each with a concrete reason tied to open
/// work, an overdue cadence, or a strong relationship going quiet.
///
/// This is the "proactive chief of staff" surface — it scans the user's
/// relationships and work and surfaces the opportunities, rather than making
/// the user scroll an alphabetical address book.
struct ReconnectSuggestionsSection: View {
    let suggestions: [MobileAPIClient.RemoteReconnectSuggestion]
    let contactsByID: [UUID: CRMContact]
    let onReachedOut: (CRMContact) -> Void

    var body: some View {
        if !suggestions.isEmpty {
            Section {
                ForEach(suggestions) { suggestion in
                    row(for: suggestion)
                }
            } header: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.tint)
                    Text("Reconnect")
                }
            } footer: {
                Text("People worth reaching out to, based on your work and how you usually keep in touch.")
            }
        }
    }

    @ViewBuilder
    private func row(for suggestion: MobileAPIClient.RemoteReconnectSuggestion) -> some View {
        if let contact = contact(for: suggestion) {
            NavigationLink {
                ContactDetailView(contact: contact)
            } label: {
                ReconnectCard(suggestion: suggestion)
            }
            .swipeActions(edge: .trailing) {
                Button {
                    onReachedOut(contact)
                } label: {
                    Label(CRMViewCopy.reachedOutActionTitle, systemImage: "phone.arrow.up.right")
                }
                .tint(.blue)
            }
        } else {
            ReconnectCard(suggestion: suggestion)
        }
    }

    private func contact(for suggestion: MobileAPIClient.RemoteReconnectSuggestion) -> CRMContact? {
        guard let uuid = UUID(uuidString: suggestion.person.id) else { return nil }
        return contactsByID[uuid]
    }
}

private struct ReconnectCard: View {
    let suggestion: MobileAPIClient.RemoteReconnectSuggestion

    private var category: ReconnectCategory {
        ReconnectPresentation.category(for: suggestion)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: category.systemImage)
                    .font(.subheadline)
                    .foregroundStyle(category.tint)
                    .accessibilityHidden(true)

                Text(suggestion.person.displayName)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                StatusPill(title: category.label, tint: category.tint)
            }

            Text(suggestion.reason)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let signal = ReconnectPresentation.signalLine(for: suggestion) {
                Text(signal)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let action = suggestion.suggestedAction, !action.isEmpty {
                Label(action, systemImage: "arrow.turn.up.right")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }
}
