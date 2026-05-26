@preconcurrency import EventKit
import Foundation

/// Thin wrapper around `EKEventStore` for reading Calendar events. Kept
/// off-main and `Sendable` so the source's polling task can drive it
/// from a detached priority-utility `Task`.
///
/// EventKit on macOS 14+ requires `requestFullAccessToEvents` and a
/// matching `NSCalendarsFullAccessUsageDescription` Info.plist string.
/// Older "calendar read-only" access is no longer a supported tier —
/// the only option for an app that enumerates every calendar is full
/// access. We deliberately don't write back, even though the entitlement
/// would allow it.
///
/// The reader expands recurring events into one snapshot per occurrence
/// within the requested window. EventKit's
/// `events(matching:)` already returns one `EKEvent` per occurrence
/// (with the recurrence rule resolved against the predicate window), so
/// the server stores one row per occurrence and date-window queries
/// never have to evaluate RRULEs at query time. Each occurrence inherits
/// the master event's identifier with a date-tagged suffix so the
/// `(user, device, source, guid)` unique constraint keeps the rows
/// distinct.
///
/// `@unchecked Sendable` mirrors `RemindersReader` — `EKEventStore` is
/// thread-safe per Apple's documentation but the headers don't declare
/// it `Sendable`. We only ever hand the store to read-only EventKit
/// APIs that document safe concurrent access.
struct CalendarEventReader: @unchecked Sendable {
    enum AuthorizationOutcome: Equatable, Sendable {
        case authorized
        case denied
        case restricted
        case notDetermined
        case writeOnly
    }

    enum ReaderError: Error, Equatable, Sendable {
        case notAuthorized
    }

    /// Snapshot of a single event occurrence. Decoupled from `EKEvent`
    /// so it can cross actor boundaries cleanly.
    struct Snapshot: Sendable, Equatable {
        /// Per-occurrence identifier. For recurring events this is the
        /// EventKit `eventIdentifier` plus an ISO-8601 start suffix; for
        /// one-shot events it's the identifier verbatim. The suffix is
        /// what lets the server keep one row per occurrence even though
        /// EventKit reuses the master id for every recurrence instance.
        let guid: String
        /// The underlying EventKit identifier (the master id, shared by
        /// every occurrence). Useful for logs and for jumping back to
        /// the source event if we ever wire a "show in Calendar.app"
        /// affordance.
        let masterIdentifier: String
        let calendarName: String?
        let calendarColor: String?
        let title: String?
        let notes: String?
        let location: String?
        let startAt: Date
        let endAt: Date
        let isAllDay: Bool
        let isRecurring: Bool
        let organizerEmail: String?
        let attendeesCount: Int
        let attendeeEmails: [String]
        let createdAt: Date?
        let modifiedAt: Date?
    }

    private let store: EKEventStore
    private let authorizationProbe: @Sendable () -> EKAuthorizationStatus
    /// Test seam: when set, `fetchEvents(start:end:)` returns this
    /// closure's output instead of hitting EventKit. Tests use the
    /// secondary initializer to inject; production callers leave it
    /// nil and the live store path runs.
    private let fetchOverride: (@Sendable (Date, Date) async throws -> [Snapshot])?
    /// Test seam: when set, `requestAccess()` returns this value
    /// without prompting.
    private let accessGrantOverride: Bool?

    init(
        store: EKEventStore = EKEventStore(),
        authorizationProbe: @escaping @Sendable () -> EKAuthorizationStatus = {
            EKEventStore.authorizationStatus(for: .event)
        },
        fetchOverride: (@Sendable (Date, Date) async throws -> [Snapshot])? = nil,
        accessGrantOverride: Bool? = nil
    ) {
        self.store = store
        self.authorizationProbe = authorizationProbe
        self.fetchOverride = fetchOverride
        self.accessGrantOverride = accessGrantOverride
    }

    /// Current authorization state mapped to our enum.
    /// `EKAuthorizationStatus.fullAccess` lands here on macOS 14+; older
    /// `.authorized` raw value also satisfies the green path on older
    /// systems.
    func authorizationState() -> AuthorizationOutcome {
        switch authorizationProbe() {
        case .authorized, .fullAccess:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        case .writeOnly:
            return .writeOnly
        @unknown default:
            return .denied
        }
    }

    /// Trigger the OS prompt for full calendar access. Idempotent — if
    /// the user has already chosen, EventKit returns the same decision
    /// without re-prompting.
    func requestAccess() async throws -> Bool {
        if let accessGrantOverride {
            return accessGrantOverride
        }
        return try await store.requestFullAccessToEvents()
    }

    /// Fetch every event in `[start, end]` across every accessible
    /// calendar (iCloud + Exchange + Google CalDAV + local). EventKit's
    /// `events(matching:)` is synchronous and already expands recurring
    /// events into one `EKEvent` per occurrence inside the window, so
    /// the caller never has to re-evaluate RRULEs.
    func fetchEvents(start: Date, end: Date) async throws -> [Snapshot] {
        guard authorizationState() == .authorized else {
            throw ReaderError.notAuthorized
        }
        if let fetchOverride {
            return try await fetchOverride(start, end)
        }
        let store = self.store
        return await Task.detached(priority: .utility) {
            let predicate = store.predicateForEvents(
                withStart: start,
                end: end,
                calendars: nil
            )
            let events = store.events(matching: predicate)
            return events.map(Self.snapshot(from:))
        }.value
    }

    /// Pure mapping from `EKEvent` to our wire-ready `Snapshot`.
    nonisolated static func snapshot(from event: EKEvent) -> Snapshot {
        let calendar = event.calendar
        let calendarName = calendar?.title
        let calendarColor = calendar?.cgColor.map(hex(from:))

        let masterIdentifier = event.eventIdentifier ?? event.calendarItemIdentifier
        let guid = derivedGuid(masterIdentifier: masterIdentifier, startAt: event.startDate)

        let organizerEmail: String? = {
            guard let raw = event.organizer?.url.absoluteString else { return nil }
            return emailFromMailto(raw)
        }()

        let attendeeEmails: [String]
        if let attendees = event.attendees {
            attendeeEmails = attendees.compactMap { att in
                emailFromMailto(att.url.absoluteString)
            }
        } else {
            attendeeEmails = []
        }

        return Snapshot(
            guid: guid,
            masterIdentifier: masterIdentifier,
            calendarName: calendarName,
            calendarColor: calendarColor,
            title: event.title,
            notes: event.notes,
            location: event.location,
            startAt: event.startDate ?? Date(),
            endAt: event.endDate ?? event.startDate ?? Date(),
            isAllDay: event.isAllDay,
            isRecurring: event.hasRecurrenceRules,
            organizerEmail: organizerEmail,
            attendeesCount: attendeeEmails.count,
            attendeeEmails: attendeeEmails,
            createdAt: event.creationDate,
            modifiedAt: event.lastModifiedDate
        )
    }

    /// One row per occurrence requires per-occurrence guids. EventKit
    /// reuses the master `eventIdentifier` for every occurrence of a
    /// recurring event, so we append an ISO-8601 start timestamp to
    /// guarantee uniqueness under the server's
    /// `(user, device, source, guid)` unique index. Non-recurring events
    /// keep the bare identifier so re-syncs deduplicate cleanly.
    nonisolated static func derivedGuid(
        masterIdentifier: String,
        startAt: Date?
    ) -> String {
        guard let startAt else { return masterIdentifier }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return "\(masterIdentifier)@\(formatter.string(from: startAt))"
    }

    /// EventKit hands us `mailto:` URLs for attendees and organizers.
    /// Strip the scheme so the server stores plain `user@example.com`.
    nonisolated static func emailFromMailto(_ raw: String) -> String? {
        let lower = raw.lowercased()
        if lower.hasPrefix("mailto:") {
            let suffix = raw.dropFirst("mailto:".count)
            if suffix.isEmpty { return nil }
            return String(suffix)
        }
        // Some attendee URLs are bare addresses; accept those too.
        if raw.contains("@") { return raw }
        return nil
    }

    /// Convert a `CGColor` into `#RRGGBB`. Mirrors the helper on
    /// `RemindersReader` — copied here so the modules stay independent
    /// rather than tying calendar mapping to the reminders module.
    private nonisolated static func hex(from cgColor: CGColor) -> String {
        let components = cgColor.components ?? []
        let r = components.count > 0 ? Int((components[0] * 255).rounded()) : 0
        let g = components.count > 1 ? Int((components[1] * 255).rounded()) : 0
        let b = components.count > 2 ? Int((components[2] * 255).rounded()) : 0
        return String(format: "#%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }

    private nonisolated static func clamp(_ value: Int) -> Int {
        min(max(value, 0), 255)
    }
}
