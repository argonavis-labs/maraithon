/// A complete busy-time window, with empty calendars included and no event text.
/// Replacement snapshots reconcile deletions independently of the history cursor.
@preconcurrency import EventKit
import Foundation

struct CalendarAvailabilityPayload: Encodable, Sendable {
    struct Calendar: Encodable, Sendable {
        let id: String
        let sourceID: String
        let name: String
        let sourceName: String

        init(_ calendar: EKCalendar) {
            id = calendar.calendarIdentifier
            sourceID = calendar.source?.sourceIdentifier ?? ""
            name = calendar.title.isEmpty ? "Calendar" : calendar.title
            sourceName = calendar.source?.title ?? "Calendar account"
        }

        enum CodingKeys: String, CodingKey {
            case id, name
            case sourceID = "source_id", sourceName = "source_name"
        }
    }

    struct Event: Encodable, Sendable {
        let guid: String
        let startAt: Date
        let endAt: Date
        let isAllDay: Bool
        let startDate: String?
        let endDate: String?
        let sourceState: CalendarEventState?

        init(_ event: CalendarEventReader.Snapshot) {
            guid = event.guid
            startAt = event.startAt
            endAt = event.endAt
            isAllDay = event.isAllDay
            startDate = event.startDate
            endDate = event.endDate
            sourceState = event.sourceState
        }

        enum CodingKeys: String, CodingKey {
            case guid
            case startAt = "start_at", endAt = "end_at", isAllDay = "is_all_day"
            case startDate = "start_date", endDate = "end_date", sourceState = "source_state"
        }
    }

    let version = 1
    let capturedAt: Date
    let from: Date
    let until: Date
    let calendars: [Calendar]
    let events: [Event]

    init?(window: CalendarEventReader.Window, from: Date, until: Date) {
        guard let calendars = window.calendars,
              calendars.count <= 64,
              calendars.allSatisfy({ !$0.sourceID.isEmpty }),
              from >= window.from, until <= window.until else { return nil }
        let events = window.events.filter { $0.startAt < until && $0.endAt > from }
        guard events.count <= 2_000 else { return nil }
        self.capturedAt = window.capturedAt
        self.from = from
        self.until = until
        self.calendars = calendars
        self.events = events.map(Event.init)
    }

    /// EventKit returns floating dates in the default zone. Cover every day
    /// touched, including a last-day end time, while preserving midnight as exclusive.
    static func allDayDates(start: Date?, end: Date?) -> (start: String, end: String)? {
        guard let start, let end, end > start else { return nil }
        var calendar = Foundation.Calendar(identifier: .gregorian)
        calendar.timeZone = NSTimeZone.default
        let endDay = calendar.startOfDay(for: end)
        guard let exclusiveEnd = end > endDay
                ? calendar.date(byAdding: .day, value: 1, to: endDay) : endDay else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return (formatter.string(from: start), formatter.string(from: exclusiveEnd))
    }

    func failureMetadata(_ error: Error) -> [String: String] {
        var result: [String: String] = [:]
        result["calendars"] = String(calendars.count)
        result["events"] = String(events.count)
        result["zero_duration"] = String(events.filter { $0.startAt == $0.endAt }.count)
        result["negative_duration"] = String(events.filter { $0.startAt > $0.endAt }.count)
        result["empty_calendar_fields"] = String(calendars.filter { $0.id.isEmpty || $0.sourceID.isEmpty || $0.name.isEmpty || $0.sourceName.isEmpty }.count)
        result["capture_age_seconds"] = String(Int(Date().timeIntervalSince(capturedAt)))
        result["all_day_missing_dates"] = String(events.filter { $0.isAllDay && ($0.startDate == nil || $0.endDate == nil) }.count)
        result["all_day_nonincreasing_dates"] = String(events.filter { $0.isAllDay && ($0.startDate ?? "") >= ($0.endDate ?? "") }.count)
        result["all_day_bad_date_length"] = String(events.filter { $0.isAllDay && ($0.startDate?.count != 10 || $0.endDate?.count != 10) }.count)
        result["timed_dates_present"] = String(events.filter { !$0.isAllDay && ($0.startDate != nil || $0.endDate != nil) }.count)
        if case MaraithonClientError.clientError(let status, let body) = error {
            result["http_status"] = String(status)
            if let data = body?.data(using: .utf8),
               let value = try? JSONDecoder().decode([String: String].self, from: data),
               let code = value["error"],
               Self.failureCodes.contains(code) {
                result["reason"] = code
            }
        } else if case MaraithonClientError.serverError(let status) = error {
            result["http_status"] = String(status)
        }
        return result
    }

    private static let failureCodes = Set(
        ["invalid_calendar_availability", "stale_calendar_availability", "device_revoked", "device_mismatch", "privacy_erasure_requested"] +
        ["fields", "version", "captured_at", "freshness", "from", "until", "window", "calendars", "calendar_fields", "calendar_ids", "events", "bytes", "event_fields", "event_state", "event_calendar", "event_start", "event_end", "event_duration", "event_window", "event_dates"].map { "invalid_calendar_availability_\($0)" }
    )

    enum CodingKeys: String, CodingKey {
        case version, from, until, calendars, events
        case capturedAt = "captured_at"
    }
}
