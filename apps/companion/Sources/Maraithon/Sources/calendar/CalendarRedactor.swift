/// Redaction helper for calendar title / notes / location content.
/// Calendar text is just as user-written as notes / reminders, so we
/// never log it verbatim — only a length-tagged short prefix.
///
/// Kept as a free enum (not a method on the source) so detached
/// `Task`s can call it without touching `@MainActor` state.
enum CalendarRedactor {
    static let prefixLength = 12

    static func redact(_ text: String?) -> String {
        guard let text else { return "<nil>" }
        if text.count <= prefixLength {
            return "[len=\(text.count)] \(text)"
        }
        let prefix = String(text.prefix(prefixLength))
        return "[len=\(text.count)] \(prefix)…"
    }
}
