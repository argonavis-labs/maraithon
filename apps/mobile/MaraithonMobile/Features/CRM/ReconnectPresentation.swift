import SwiftUI

/// Pure presentation rules for the "Reconnect" surface — the intelligent
/// layer of the People tab that surfaces who the user should reach out to
/// and why, instead of a flat A-Z directory.
///
/// Kept free of SwiftUI view code so the category mapping and the
/// human-readable signal line can be unit-tested directly.
enum ReconnectCategory: String, Equatable {
    case openWork = "open_work"
    case goalAligned = "goal_aligned"
    case overdue
    case goingQuiet = "going_quiet"
    case unknown

    init(apiValue: String) {
        self = ReconnectCategory(rawValue: apiValue) ?? .unknown
    }

    var label: String {
        switch self {
        case .openWork: "Open work"
        case .goalAligned: "Goal"
        case .overdue: "Overdue"
        case .goingQuiet: "Going quiet"
        case .unknown: "Reconnect"
        }
    }

    var systemImage: String {
        switch self {
        case .openWork: "checklist"
        case .goalAligned: "target"
        case .overdue: "clock.badge.exclamationmark"
        case .goingQuiet: "person.crop.circle.badge.moon"
        case .unknown: "person.2"
        }
    }

    var tint: Color {
        switch self {
        case .openWork: .blue
        case .goalAligned: .purple
        case .overdue: .orange
        case .goingQuiet: .purple
        case .unknown: .accentColor
        }
    }
}

enum ReconnectPresentation {
    static func category(for suggestion: MobileAPIClient.RemoteReconnectSuggestion) -> ReconnectCategory {
        ReconnectCategory(apiValue: suggestion.category)
    }

    /// A short "cadence / recency" line shown under the reason, e.g.
    /// "12d quiet · usually every 7d" or "24d since last contact".
    static func signalLine(for suggestion: MobileAPIClient.RemoteReconnectSuggestion) -> String? {
        let days = suggestion.daysSinceLast
        let cadence = suggestion.cadenceDays

        switch (days, cadence) {
        case let (days?, cadence?):
            return "\(days)d quiet · usually every \(cadenceLabel(cadence))"
        case let (days?, nil):
            return "\(days)d since last contact"
        default:
            return nil
        }
    }

    static func cadenceLabel(_ days: Int) -> String {
        switch days {
        case ..<2: "day"
        case ..<10: "\(days)d"
        case ..<14: "week or two"
        case ..<36: "month"
        default: "few months"
        }
    }
}
