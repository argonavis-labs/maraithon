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
                        .crmListRow()
                }
            } header: {
                HStack(spacing: Runner.Spacing.compact) {
                    Image(systemName: "sparkles")
                        .font(Runner.Typography.caption)
                        .foregroundStyle(Runner.Palette.accent)
                        .accessibilityHidden(true)
                    RunnerSectionLabel("Reconnect")
                }
                .padding(.horizontal, Runner.Layout.pageInset)
                .padding(.top, Runner.Spacing.roomy)
                .padding(.bottom, Runner.Spacing.xsmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Runner.Palette.background)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text("People worth reaching out to, based on your work and how you usually keep in touch.")
                    .font(Runner.Typography.caption)
                    .foregroundStyle(Runner.Palette.mutedForeground)
                    .padding(.horizontal, Runner.Layout.pageInset)
                    .padding(.top, Runner.Spacing.small)
                    .listRowInsets(EdgeInsets())
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
                .tint(Runner.Palette.info)
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

    private var tone: RunnerBadge.Tone {
        RunnerBadge.Tone.from(tint: category.tint)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Runner.Spacing.small) {
            HStack(spacing: Runner.Spacing.small) {
                Image(systemName: category.systemImage)
                    .font(Runner.Typography.small)
                    .foregroundStyle(tone.text)
                    .accessibilityHidden(true)

                Text(suggestion.person.displayName)
                    .font(Runner.Typography.bodyMedium)
                    .foregroundStyle(Runner.Palette.foreground)
                    .lineLimit(1)

                Spacer(minLength: Runner.Spacing.small)

                StatusPill(title: category.label, tint: category.tint)
            }

            Text(suggestion.reason)
                .font(Runner.Typography.small)
                .foregroundStyle(Runner.Palette.foreground80)
                .fixedSize(horizontal: false, vertical: true)

            if let signal = ReconnectPresentation.signalLine(for: suggestion) {
                Text(signal)
                    .font(Runner.Typography.caption)
                    .foregroundStyle(Runner.Palette.mutedForeground)
            }

            if let action = suggestion.suggestedAction, !action.isEmpty {
                Label(action, systemImage: "arrow.turn.up.right")
                    .font(Runner.Typography.caption)
                    .foregroundStyle(Runner.Palette.accent)
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Runner.Spacing.xsmall)
    }
}
