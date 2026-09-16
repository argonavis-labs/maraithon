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

    static func localDate(_ date: Date?, timezone: TimeZone?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Foundation.Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timezone ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    enum CodingKeys: String, CodingKey {
        case version, from, until, calendars, events
        case capturedAt = "captured_at"
    }
}
