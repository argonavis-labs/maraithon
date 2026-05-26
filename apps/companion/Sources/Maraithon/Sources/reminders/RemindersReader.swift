@preconcurrency import EventKit
import Foundation

/// Thin wrapper around `EKEventStore` for reading Reminders. Kept
/// off-main and `Sendable` so the source's polling task can drive it
/// from a detached priority-utility `Task`.
///
/// EventKit on macOS 14+ requires `requestFullAccessToReminders` and a
/// matching `NSRemindersFullAccessUsageDescription` Info.plist string.
/// Read-only access is no longer a supported access level — the only
/// option for an app that needs to enumerate every reminder is full
/// access. We deliberately don't write back, even though the entitlement
/// would allow it.
/// `@unchecked Sendable` because `EKEventStore` is thread-safe per
/// Apple's documentation but isn't declared `Sendable` in the
/// EventKit headers. We only ever hand the store to read-only
/// EventKit APIs that document safe concurrent access.
struct RemindersReader: @unchecked Sendable {
    /// Result of the authorization probe / request.
    enum AuthorizationOutcome: Equatable, Sendable {
        case authorized
        case denied
        case restricted
        case notDetermined
        case writeOnly
    }

    /// Errors a fetch can raise before we even get to EventKit's own
    /// callback-side errors.
    enum ReaderError: Error, Equatable, Sendable {
        case notAuthorized
    }

    /// Snapshot of a single reminder, decoupled from `EKReminder` so we
    /// can pass it across actor boundaries cleanly. Mirrors
    /// `ReminderPayload` field-for-field minus the wire-only `localId`.
    struct Snapshot: Sendable, Equatable {
        let guid: String
        let title: String?
        let notes: String?
        let listName: String?
        let listColor: String?
        let priority: Int
        let dueAt: Date?
        let completedAt: Date?
        let isCompleted: Bool
        let hasAlarm: Bool
        let urlAttachment: String?
        let createdAt: Date?
        let modifiedAt: Date?
    }

    private let store: EKEventStore
    private let authorizationProbe: @Sendable () -> EKAuthorizationStatus
    /// Optional fetch override used by tests so the source's polling
    /// path can be exercised without granting Reminders access to the
    /// test bundle. Production callers leave it `nil`; the public
    /// `fetchAllReminders` falls back to the live EventKit query.
    private let fetchOverride: (@Sendable () async throws -> [Snapshot])?

    init(
        store: EKEventStore = EKEventStore(),
        authorizationProbe: @escaping @Sendable () -> EKAuthorizationStatus = {
            EKEventStore.authorizationStatus(for: .reminder)
        },
        fetchOverride: (@Sendable () async throws -> [Snapshot])? = nil
    ) {
        self.store = store
        self.authorizationProbe = authorizationProbe
        self.fetchOverride = fetchOverride
    }

    /// Current authorization state mapped to our four-case enum.
    /// `EKAuthorizationStatus` has a `.fullAccess` case on macOS 14+
    /// that the older `.authorized` raw value also satisfies on older
    /// systems — we treat both as "go".
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

    /// Trigger the OS prompt for full reminders access. Idempotent —
    /// if the user has already chosen, EventKit returns the same
    /// decision without re-prompting.
    func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToReminders()
    }

    /// Fetch every reminder in every accessible list (iCloud + local).
    /// EventKit's `fetchReminders(matching:completion:)` uses a
    /// callback; we wrap it in a continuation so callers can `await`.
    ///
    /// We bridge `EKReminder` to `Snapshot` inside the callback so the
    /// non-`Sendable` `EKReminder` reference never leaks out of the
    /// EventKit calendar thread.
    func fetchAllReminders() async throws -> [Snapshot] {
        guard authorizationState() == .authorized else {
            throw ReaderError.notAuthorized
        }
        if let fetchOverride {
            return try await fetchOverride()
        }
        let predicate = store.predicateForReminders(in: nil)
        return try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                guard let reminders else {
                    continuation.resume(returning: [])
                    return
                }
                let snapshots = reminders.map(Self.snapshot(from:))
                continuation.resume(returning: snapshots)
            }
        }
    }

    /// Pure mapping from `EKReminder` to our wire-ready `Snapshot`.
    /// Kept `nonisolated static` so tests can call it without
    /// constructing a reader (and without involving EventKit's
    /// calendar thread).
    nonisolated static func snapshot(from reminder: EKReminder) -> Snapshot {
        let identifier = reminder.calendarItemIdentifier
        let calendar = reminder.calendar
        let listName = calendar?.title
        let listColor = calendar?.cgColor.map(hex(from:))

        // `dueDateComponents` is the canonical source of truth. We
        // convert it through the user's calendar so the wire timestamp
        // matches what Reminders.app actually shows.
        let dueAt: Date?
        if let components = reminder.dueDateComponents {
            dueAt = Calendar.current.date(from: components)
        } else {
            dueAt = nil
        }

        // EventKit gives us `hasAlarms` as a Bool; we project it to a
        // typed field so the server doesn't need to count `alarms`.
        let hasAlarm = (reminder.alarms?.isEmpty == false)

        return Snapshot(
            guid: identifier,
            title: reminder.title,
            notes: reminder.notes,
            listName: listName,
            listColor: listColor,
            priority: reminder.priority,
            dueAt: dueAt,
            completedAt: reminder.completionDate,
            isCompleted: reminder.isCompleted,
            hasAlarm: hasAlarm,
            urlAttachment: reminder.url?.absoluteString,
            createdAt: reminder.creationDate,
            modifiedAt: reminder.lastModifiedDate
        )
    }

    /// Convert a `CGColor` into a `#RRGGBB` string. Falls back to the
    /// system accent colour when the calendar has no explicit colour.
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
