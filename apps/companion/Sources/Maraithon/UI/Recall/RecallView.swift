import SwiftUI

/// Desktop Recall panel. Cross-source semantic + substring search over
/// every mirror the user has paired (iMessage, Notes, Voice Memos,
/// Calendar, Reminders, Files, Browser History, Gmail, Slack, CRM,
/// deep memory) in one input box.
///
/// UX choices:
///   - Single `TextField` at the top with a magnifying-glass prompt.
///   - Results render as a clean `List` with one row per hit, ordered
///     by descending recall score (the server's blended recency +
///     substring + source-trust signal).
///   - Each row shows the source icon, title, snippet, and a relative
///     date so the user can verify provenance at a glance.
///   - Tapping a row opens the underlying record in the native macOS
///     app via URL scheme when possible (notes://, reminders://,
///     ical://, voicememos://, messages://) and falls back to a
///     read-only in-app preview otherwise.
struct RecallView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var query: String = ""
    @State private var results: [RecallResult] = []
    @State private var isSearching: Bool = false
    @State private var lastError: String? = nil
    @State private var lastQuery: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.medium) {
            searchField

            if let lastError {
                Label(lastError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if isSearching {
                ProgressView(RecallCopy.searchingLabel)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 240)
            } else if !lastQuery.isEmpty && results.isEmpty {
                ContentUnavailableView(
                    RecallCopy.noMatchesTitle,
                    systemImage: "magnifyingglass",
                    description: Text(RecallCopy.noMatchesDescription(for: lastQuery))
                )
            } else if results.isEmpty {
                placeholder
            } else {
                resultsList
            }
        }
        .padding(Tokens.Spacing.large)
        .navigationTitle("Recall")
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: Tokens.Spacing.small) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Ask anything across your Mac…", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            Button(RecallCopy.searchButtonTitle) { submit() }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - Results list

    private var resultsList: some View {
        List(results) { hit in
            Button {
                open(hit)
            } label: {
                RecallResultRow(hit: hit)
            }
            .buttonStyle(.plain)
        }
        .listStyle(.inset)
    }

    private var placeholder: some View {
        ContentUnavailableView(
            "Recall anything",
            systemImage: "magnifyingglass.circle",
            description: Text("Notes, Messages, Voice Memos, Calendar, Reminders, Files, Browser History — one search across all of them.")
        )
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

private struct RecallResultRow: View {
    let hit: RecallResult

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.medium) {
            Image(systemName: symbol(for: hit.source))
                .foregroundStyle(.secondary)
                .frame(width: Tokens.IconSize.regular)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Tokens.Spacing.small) {
                    Text(RecallCopy.resultTitle(for: hit))
                        .font(.callout)
                        .lineLimit(1)
                    Spacer()
                    Text(relativeDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let snippet = hit.snippet, !snippet.isEmpty {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(RecallCopy.sourceLabel(for: hit.source))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, Tokens.Spacing.xsmall)
    }

    private var relativeDate: String {
        guard let ts = hit.timestamp else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: ts, relativeTo: Date())
    }

    private func symbol(for source: String) -> String {
        switch source {
        case "local_messages": return "message"
        case "local_notes": return "note.text"
        case "local_voice_memos": return "waveform"
        case "local_calendar": return "calendar"
        case "local_reminders": return "checklist"
        case "local_files": return "doc.text"
        case "local_browser_history": return "safari"
        case "maraithon_memory": return "brain"
        case "crm_people": return "person.crop.circle"
        default: return "doc"
        }
    }

}

enum RecallCopy {
    static let searchingLabel = "Searching…"
    static let searchButtonTitle = "Search"
    static let noMatchesTitle = "Checked sources did not match"

    static func searchError(_ error: Error) -> String {
        "Search could not finish. \(CompanionErrorCopy.message(for: error))"
    }

    static func noMatchesDescription(for query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = trimmed.isEmpty
            ? "Maraithon checked available sources."
            : "Maraithon checked available sources for \"\(trimmed)\"."
        return "\(prefix) Try a person, thread, phrase, or date from sources Maraithon has already checked."
    }

    static func resultTitle(for hit: RecallResult) -> String {
        if let title = hit.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }

        switch hit.source {
        case "local_messages": return "Message"
        case "local_notes": return "Note"
        case "local_voice_memos": return "Voice memo"
        case "local_calendar": return "Calendar event"
        case "local_reminders": return "Reminder"
        case "local_files": return "File"
        case "local_browser_history": return "Browser visit"
        case "maraithon_memory": return "Memory"
        case "crm_people": return "Contact"
        default: return "Search result"
        }
    }

    static func sourceLabel(for source: String) -> String {
        switch source {
        case "local_messages": return "Messages"
        case "local_notes": return "Notes"
        case "local_voice_memos": return "Voice Memos"
        case "local_calendar": return "Calendar"
        case "local_reminders": return "Reminders"
        case "local_files": return "Files"
        case "local_browser_history": return "Browser History"
        case "maraithon_memory": return "Memory"
        case "crm_people": return "Contacts"
        default: return humanizedSourceLabel(source)
        }
    }

    private static func humanizedSourceLabel(_ source: String) -> String {
        let cleaned = source
            .replacingOccurrences(of: "local_", with: "")
            .replacingOccurrences(of: "maraithon_", with: "")
            .replacingOccurrences(of: "crm_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return "Synced source" }

        return cleaned
            .split(separator: " ")
            .map { word in
                word.prefix(1).uppercased() + String(word.dropFirst())
            }
            .joined(separator: " ")
    }
}

#Preview("Empty") {
    RecallView()
        .environment(AppEnvironment())
        .frame(width: 700, height: 500)
}
