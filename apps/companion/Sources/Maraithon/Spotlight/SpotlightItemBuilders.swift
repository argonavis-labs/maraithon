import CoreSpotlight
import Foundation
import NaturalLanguage
import UniformTypeIdentifiers

/// Builders that convert each source's typed wire payload into a
/// `CSSearchableItem` ready to hand to `SpotlightIndexer.index(items:)`.
///
/// Why builders live here and not on the payload types themselves:
///   * The payloads are wire shapes co-located with their `*Ingest.swift`
///     files. Keeping the Spotlight wiring separate means a future
///     server-contract tweak doesn't drag Spotlight into the diff.
///   * `CSSearchableItem` is reference-typed and not `Sendable`, so
///     building it inside the `Sources/Maraithon/Spotlight` module lets
///     us contain the non-Sendability instead of leaking it into wire
///     types.
///
/// All builders cap `contentDescription` at `Self.descriptionLimit`
/// characters so Spotlight gets a short, scannable snippet — Apple's
/// indexer truncates internally but we prefer keeping payloads small
/// on principle.
enum SpotlightItemBuilders {
    /// Hard cap on the description snippet length. 400 chars is well
    /// under what Spotlight surfaces in its result row but long
    /// enough that a "first paragraph" preview fits.
    static let descriptionLimit: Int = 400

    /// Build a `CSSearchableItem` for a synced note.
    static func item(forNote note: NoteRecord) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: UTType.text)
        let title = note.title?.isEmpty == false ? note.title : "Untitled note"
        attrs.title = title
        attrs.displayName = title
        let snippet = note.snippet?.isEmpty == false ? note.snippet : note.body
        attrs.contentDescription = Self.clip(snippet)
        attrs.keywords = Self.keywords(from: title, body: note.body ?? note.snippet)
        attrs.contentCreationDate = Self.parseISO(note.createdAt)
        attrs.contentModificationDate = Self.parseISO(note.modifiedAt)
        return Self.makeItem(
            source: "notes",
            guid: note.guid,
            attributeSet: attrs
        )
    }

    /// Build a `CSSearchableItem` for a synced voice memo.
    static func item(forVoiceMemo memo: VoiceMemoPayload) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: UTType.audio)
        attrs.title = memo.title
        attrs.displayName = memo.title
        // Transcripts are the most search-useful field for a voice
        // memo. Fall back to the title-derived description when no
        // transcript is available.
        attrs.contentDescription = Self.clip(memo.transcript)
        attrs.keywords = Self.keywords(from: memo.title, body: memo.transcript)
        attrs.contentCreationDate = memo.createdAt
        attrs.contentModificationDate = memo.createdAt
        return Self.makeItem(
            source: "voice_memos",
            guid: memo.guid,
            attributeSet: attrs
        )
    }

    /// Build a `CSSearchableItem` for a synced reminder.
    static func item(forReminder reminder: ReminderPayload) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: UTType.text)
        let title = reminder.title?.isEmpty == false ? reminder.title : "Reminder"
        attrs.title = title
        attrs.displayName = title
        attrs.contentDescription = Self.clip(reminder.notes)
        attrs.keywords = Self.keywords(
            from: title,
            body: reminder.notes,
            extra: reminder.listName.map { [$0] } ?? []
        )
        attrs.contentCreationDate = reminder.createdAt
        attrs.contentModificationDate = reminder.modifiedAt
        attrs.dueDate = reminder.dueAt
        return Self.makeItem(
            source: "reminders",
            guid: reminder.guid,
            attributeSet: attrs
        )
    }

    /// Build a `CSSearchableItem` for a synced calendar event.
    static func item(forCalendarEvent event: CalendarEventPayload) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: UTType.calendarEvent)
        let title = event.title?.isEmpty == false ? event.title : "Untitled event"
        attrs.title = title
        attrs.displayName = title
        attrs.contentDescription = Self.clip(event.notes)
        attrs.keywords = Self.keywords(
            from: title,
            body: event.notes,
            extra: [event.calendarName, event.location].compactMap { $0 }
        )
        attrs.startDate = event.startAt
        attrs.endDate = event.endAt
        attrs.contentCreationDate = event.createdAt ?? event.startAt
        attrs.contentModificationDate = event.modifiedAt ?? event.startAt
        return Self.makeItem(
            source: "calendar",
            guid: event.guid,
            attributeSet: attrs
        )
    }

    /// Build a `CSSearchableItem` for a synced file. We surface
    /// extracted text as the description when available; otherwise
    /// the row carries just the filename, useful for "I know it's a
    /// PDF called …" recall.
    static func item(forFile file: FilePayload) -> CSSearchableItem {
        let contentType = file.extension.flatMap { UTType(filenameExtension: $0) } ?? UTType.data
        let attrs = CSSearchableItemAttributeSet(contentType: contentType)
        let title = file.filename ?? file.path
        attrs.title = title
        attrs.displayName = title
        let snippet = file.textContentBase64
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        attrs.contentDescription = Self.clip(snippet ?? file.path)
        attrs.keywords = Self.keywords(from: title, body: snippet)
        attrs.contentCreationDate = file.createdAt
        attrs.contentModificationDate = file.modifiedAt
        return Self.makeItem(
            source: "files",
            guid: file.guid,
            attributeSet: attrs
        )
    }

    // MARK: - Private helpers

    /// Wrap the common configuration: unique id, domain id, and
    /// activity-identifier payload in `userInfo` so the
    /// `NSUserActivity` handler in `MaraithonApp` can route on tap.
    private static func makeItem(
        source: String,
        guid: String,
        attributeSet: CSSearchableItemAttributeSet
    ) -> CSSearchableItem {
        let unique = SpotlightDomain.uniqueIdentifier(source: source, guid: guid)
        let item = CSSearchableItem(
            uniqueIdentifier: unique,
            domainIdentifier: SpotlightDomain.identifier(forSource: source),
            attributeSet: attributeSet
        )
        return item
    }

    /// Truncate user-visible text to `descriptionLimit`. Trailing
    /// whitespace is trimmed so we don't ship the ellipsis appended to
    /// a half-line.
    private static func clip(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        if text.count <= descriptionLimit { return text }
        let prefix = String(text.prefix(descriptionLimit))
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// Derive a small keyword list from `title` and an optional body.
    /// Uses `NLTagger` for noun/verb extraction when the body is long
    /// enough to warrant it; otherwise splits the title on
    /// whitespace. We dedupe + cap at 12 entries — Spotlight uses the
    /// list as a search-time hint and a long tail past that is
    /// noise.
    static func keywords(
        from title: String?,
        body: String?,
        extra: [String] = []
    ) -> [String] {
        var collected: [String] = []
        if let title {
            collected.append(contentsOf: title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        }
        collected.append(contentsOf: extra)
        if let body, body.count > 24 {
            let tagger = NLTagger(tagSchemes: [.lexicalClass])
            tagger.string = body
            let range = body.startIndex..<body.endIndex
            tagger.enumerateTags(
                in: range,
                unit: .word,
                scheme: .lexicalClass,
                options: [.omitPunctuation, .omitWhitespace, .omitOther]
            ) { tag, tokenRange in
                guard let tag else { return true }
                if tag == .noun || tag == .verb {
                    collected.append(String(body[tokenRange]))
                }
                // Bail early once we have enough so we don't burn CPU
                // on a long note body for an unbounded keyword list.
                return collected.count < 64
            }
        }
        var seen: Set<String> = []
        var out: [String] = []
        for raw in collected {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { continue }
            let lower = trimmed.lowercased()
            if seen.contains(lower) { continue }
            seen.insert(lower)
            out.append(trimmed)
            if out.count >= 12 { break }
        }
        return out
    }

    // ISO8601DateFormatter is documented as thread-safe but not
    // formally Sendable. `nonisolated(unsafe)` is the right escape
    // hatch — same pattern used by the source-side ISO formatters.
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parseISO(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return isoFormatter.date(from: s)
    }
}
