import Foundation

/// User-facing copy for the Recall page: header, search field, states,
/// and the per-source labels used in result rows.
///
/// Invariant: source labels never leak raw `local_*` / `crm_*`
/// identifiers; unknown sources are humanized.
enum RecallCopy {
    static let eyebrow = "Workspace"
    static let title = "Recall"
    static let subtitle = "One search across Notes, Messages, Voice Memos, Calendar, Reminders, Files, and Browser History."
    static let searchPlaceholder = "Ask anything across your Mac…"
    static let placeholderTitle = "Recall anything"
    static let placeholderDescription = "Notes, Messages, Voice Memos, Calendar, Reminders, Files, Browser History — one search across all of them."
    static let searchingLabel = "Searching…"
    static let searchButtonTitle = "Search"
    static let noMatchesTitle = "No matching context available"

    static func searchError(_ error: Error) -> String {
        "Search could not finish. \(CompanionErrorCopy.message(for: error))"
    }

    static func noMatchesDescription(for query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = trimmed.isEmpty
            ? "Maraithon searched context already available to your assistant."
            : "Maraithon searched context already available to your assistant for \"\(trimmed)\"."
        return "\(prefix) Try another person, thread, phrase, or date from that context."
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

        guard !cleaned.isEmpty else { return "Source" }

        return cleaned
            .split(separator: " ")
            .map { word in
                word.prefix(1).uppercased() + String(word.dropFirst())
            }
            .joined(separator: " ")
    }
}
