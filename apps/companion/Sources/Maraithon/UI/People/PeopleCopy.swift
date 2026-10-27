import Foundation
import PeopleNetworkKit

/// User-facing labels for the People page: sort options, relative contact
/// times, and the footer summary, mirroring the web People list.
enum PeopleCopy {
    enum Sort: String, CaseIterable, Identifiable {
        case affinity
        case recent
        case active
        case name

        var id: String { rawValue }

        var title: String {
            switch self {
            case .affinity: return "Affinity"
            case .recent: return "Recently active"
            case .active: return "Most active"
            case .name: return "Name"
            }
        }

        var footerLabel: String { "Sorted by \(title.lowercased())" }

        func apply(_ people: [PeopleNetworkData.Person]) -> [PeopleNetworkData.Person] {
            switch self {
            case .affinity:
                return people.sorted { $0.rank > $1.rank }
            case .recent:
                return people.sorted { (PeopleCopy.date($0.lastAt) ?? .distantPast) > (PeopleCopy.date($1.lastAt) ?? .distantPast) }
            case .active:
                return people.sorted { ($0.activeDays, $0.messageCount) > ($1.activeDays, $1.messageCount) }
            case .name:
                return people.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        }
    }

    static let historyOptions = [30, 90, 180]

    static func historyLabel(_ days: Int) -> String { "Last \(days) days" }

    static func lastContact(_ value: String?, now: Date = Date()) -> String {
        guard let date = date(value) else { return "No exchange yet" }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days < 30 { return "\(days)d ago" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func absoluteContact(_ value: String?) -> String {
        guard let date = date(value) else { return "No exchange yet" }
        return date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
    }

    static func updatedLabel(_ value: String?, now: Date = Date()) -> String? {
        guard let date = date(value) else { return nil }
        return "Updated \(lastContact(value, now: now))"
    }

    static func summary(visible: Int, known: Int, query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return visible == 1 ? "1 match" : "\(visible) matches"
        }
        if known > visible {
            return "Top \(visible) of \(known) people"
        }
        return visible == 1 ? "1 person" : "\(visible) people"
    }

    static func emptyTitle(query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No people yet" : "No people match this search"
    }

    static func emptyDescription(query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "They appear as your connected sources sync."
            : "Try a name, email, company, or note."
    }

    static func channels(_ person: PeopleNetworkData.Person) -> String {
        let names = person.channels
            .sorted { $0.count > $1.count }
            .map { channelName($0.source) }
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        return unique.joined(separator: " · ")
    }

    static func channelName(_ source: String) -> String {
        switch source {
        case "gmail": return "Email"
        case "slack": return "Slack"
        case "whatsapp": return "WhatsApp"
        case "calendar", "google_calendar": return "Calendar"
        case "imessage", "messages": return "Messages"
        default: return source.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func rankLabel(_ rank: Double) -> String {
        rank >= 10 ? String(Int(rank.rounded())) : String(format: "%.1f", rank)
    }

    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
