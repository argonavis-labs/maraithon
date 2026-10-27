import Foundation

enum RelationshipCareLevel: Int, Equatable, Comparable {
    case archived
    case warm
    case new
    case due
    case needsCare

    static func < (lhs: RelationshipCareLevel, rhs: RelationshipCareLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct RelationshipCareSummary: Equatable {
    let level: RelationshipCareLevel
    let title: String
    let subtitle: String
    let actionTitle: String
    let systemImage: String
}

enum RelationshipCareSignal {
    static func summary(
        for contact: CRMContact,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> RelationshipCareSummary {
        if contact.status == .closed || contact.dealStage == .lost {
            return RelationshipCareSummary(
                level: .archived,
                title: "Archived",
                subtitle: "No active follow-up",
                actionTitle: "Review",
                systemImage: "archivebox"
            )
        }

        if contact.status == .atRisk {
            return RelationshipCareSummary(
                level: .needsCare,
                title: "Needs care",
                subtitle: contact.lastContactedAt.map { "Last contact \(relativeDays(from: $0, to: now, calendar: calendar))" } ?? "No recent contact",
                actionTitle: "Follow up",
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
        }

        guard let lastContactedAt = contact.lastContactedAt else {
            return RelationshipCareSummary(
                level: .new,
                title: "First touch",
                subtitle: "No contact logged yet",
                actionTitle: "Log contact",
                systemImage: "person.crop.circle.badge.plus"
            )
        }

        let days = daysBetween(lastContactedAt, now, calendar: calendar)
        switch days {
        case 14...:
            return RelationshipCareSummary(
                level: .needsCare,
                title: "Needs care",
                subtitle: "Last contact \(relativeDays(days))",
                actionTitle: "Follow up",
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
        case 7..<14:
            return RelationshipCareSummary(
                level: .due,
                title: "Check-in due",
                subtitle: "Last contact \(relativeDays(days))",
                actionTitle: "Check in",
                systemImage: "person.wave.2"
            )
        default:
            return RelationshipCareSummary(
                level: .warm,
                title: "Warm",
                subtitle: "Contacted \(relativeDays(days))",
                actionTitle: "Log contact",
                systemImage: "checkmark.circle"
            )
        }
    }

    private static func relativeDays(
        from startDate: Date,
        to endDate: Date,
        calendar: Calendar
    ) -> String {
        relativeDays(daysBetween(startDate, endDate, calendar: calendar))
    }

    private static func relativeDays(_ days: Int) -> String {
        switch days {
        case ..<1: "today"
        case 1: "1d ago"
        default: "\(days)d ago"
        }
    }

    private static func daysBetween(_ startDate: Date, _ endDate: Date, calendar: Calendar) -> Int {
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        return max(0, calendar.dateComponents([.day], from: start, to: end).day ?? 0)
    }
}
