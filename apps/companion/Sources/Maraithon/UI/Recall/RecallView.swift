import SwiftUI

/// Desktop Recall page. Cross-source semantic + substring search over
/// every mirror the user has paired (iMessage, Notes, Voice Memos,
/// Calendar, Reminders, Files, Browser History, Gmail, Slack, CRM,
/// deep memory) in one input box.
///
/// UX choices:
///   - Workspace page header, then one `RunnerSearchField` and a Search
///     button.
///   - Results render as hairline-separated rows in a card, ordered by
///     descending recall score (the server's blended recency +
///     substring + source-trust signal).
///   - Each row shows the source glyph, title, snippet, and the source
///     name plus a relative date so the user can verify provenance.
///   - Clicking a row opens the underlying record in the native macOS
///     app via URL scheme when possible (notes://, reminders://,
///     ical://, voicememos://, messages://) and is a no-op otherwise.
struct RecallView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var query: String = ""
    @State private var results: [RecallResult] = []
    @State private var isSearching: Bool = false
    @State private var lastError: String? = nil
    @State private var lastQuery: String = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        RunnerPage {
            RunnerPageHeader(
                eyebrow: RecallCopy.eyebrow,
                title: RecallCopy.title,
                subtitle: RecallCopy.subtitle
            )
            searchRow
                .padding(.vertical, Tokens.Spacing.large)
            resultsCard
        }
    }

    // MARK: - Search field

    private var searchRow: some View {
        HStack(spacing: Tokens.Spacing.small) {
            RunnerSearchField(
                placeholder: RecallCopy.searchPlaceholder,
                text: $query,
                focused: $searchFocused,
                onSubmit: { submit() },
                onClear: { query = "" }
            )
            .frame(maxWidth: Tokens.Layout.searchFieldMaxWidth)

            Button(RecallCopy.searchButtonTitle) { submit() }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(RunnerButtonStyle(.primary))
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - Results

    private var resultsCard: some View {
        RunnerCard {
            if isSearching {
                searchingRow
            } else if let lastError {
                RunnerEmptyState(title: lastError)
            } else if !lastQuery.isEmpty && results.isEmpty {
                RunnerEmptyState(
                    title: RecallCopy.noMatchesTitle,
                    description: RecallCopy.noMatchesDescription(for: lastQuery)
                )
            } else if results.isEmpty {
                RunnerEmptyState(
                    title: RecallCopy.placeholderTitle,
                    description: RecallCopy.placeholderDescription
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, hit in
                        if index > 0 { RunnerHairline() }
                        RecallResultRow(hit: hit) { open(hit) }
                    }
                }
            }
        }
        .frame(minHeight: Tokens.SourcesLayout.recallResultsMinHeight, alignment: .top)
    }

    private var searchingRow: some View {
        HStack(spacing: Tokens.Spacing.small) {
            ProgressView()
                .controlSize(.small)
            Text(RecallCopy.searchingLabel)
                .font(Tokens.Typography.small)
                .foregroundStyle(Tokens.Palette.mutedForeground)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tokens.SourcesLayout.emptyStateVerticalPadding)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    private func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        lastError = nil
        lastQuery = trimmed
        Task {
            await runRecall(trimmed)
        }
    }

    private func runRecall(_ q: String) async {
        let client = MaraithonClient(
            tokenProvider: { [weak env] in
                guard let env else { return nil }
                return await MainActor.run { env.deviceAuth.currentToken }
            }
        )
        do {
            let response = try await client.recall(query: q, limit: 20)
            await MainActor.run {
                results = response.results
                isSearching = false
            }
        } catch {
            await MainActor.run {
                lastError = RecallCopy.searchError(error)
                results = []
                isSearching = false
            }
        }
    }

    /// Open the underlying record in its native macOS app where possible.
    /// Falls back to a no-op when no scheme matches — a future revision
    /// can add an in-app preview pane.
    private func open(_ hit: RecallResult) {
        guard let url = nativeURL(for: hit) else { return }
        NSWorkspace.shared.open(url)
    }

    private func nativeURL(for hit: RecallResult) -> URL? {
        guard let id = hit.id else { return nil }
        switch hit.source {
        case "local_notes":
            return URL(string: "notes://showNote?identifier=\(id)")
        case "local_reminders":
            return URL(string: "x-apple-reminderkit://REMCDReminder/\(id)")
        case "local_calendar":
            return URL(string: "ical://ekevent/\(id)")
        case "local_voice_memos":
            return URL(string: "voicememos://")
        case "local_messages":
            return URL(string: "messages://")
        default:
            return nil
        }
    }
}

#Preview("Empty") {
    RecallView()
        .environment(AppEnvironment())
        .frame(width: 700, height: 500)
}
