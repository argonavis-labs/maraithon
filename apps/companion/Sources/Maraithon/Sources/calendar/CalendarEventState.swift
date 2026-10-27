/// Captures calendar identity and explicit event state without inferring account
/// ownership, a complete sync window, or availability from missing values.
@preconcurrency import EventKit
import Foundation

struct CalendarEventState: Codable, Sendable, Equatable {
    let version: Int
    let calendarID: String?
    let sourceID: String?
    let sourceName: String?
    let externalID: String?
    let eventStatus: String
    let availability: String
    let selfResponse: String

    init(event: EKEvent) {
        version = 1
        calendarID = event.calendar?.calendarIdentifier
        sourceID = event.calendar?.source?.sourceIdentifier
        sourceName = event.calendar?.source?.title
        // EventKit's external identifier is opaque, not necessarily an iCal UID.
        externalID = event.calendarItemExternalIdentifier

        switch event.status {
        case .confirmed: eventStatus = "confirmed"
        case .tentative: eventStatus = "tentative"
        case .canceled: eventStatus = "cancelled"
        default: eventStatus = "unknown"
        }

        switch event.availability {
        case .busy: availability = "busy"
        case .free: availability = "free"
        case .tentative: availability = "tentative"
        case .unavailable: availability = "unavailable"
        default: availability = "unknown"
        }

        switch event.attendees?.first(where: { $0.isCurrentUser })?.participantStatus {
        case .pending: selfResponse = "pending"
        case .accepted: selfResponse = "accepted"
        case .declined: selfResponse = "declined"
        case .tentative: selfResponse = "tentative"
        case .delegated: selfResponse = "delegated"
        case .completed: selfResponse = "completed"
        case .inProcess: selfResponse = "in_process"
        default: selfResponse = "unknown"
        }
    }

    enum CodingKeys: String, CodingKey {
        case version, availability
        case calendarID = "calendar_id"
        case sourceID = "source_id"
        case sourceName = "source_name"
        case externalID = "external_id"
        case eventStatus = "event_status"
        case selfResponse = "self_response"
    }
}
