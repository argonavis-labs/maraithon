import Foundation

enum CRMStatusFilter: String, CaseIterable, Hashable, Identifiable {
    case all
    case lead
    case active
    case atRisk
    case closed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .lead: ContactStatus.lead.title
        case .active: ContactStatus.active.title
        case .atRisk: ContactStatus.atRisk.title
        case .closed: ContactStatus.closed.title
        }
    }

    var status: ContactStatus? {
        switch self {
        case .all: nil
        case .lead: .lead
        case .active: .active
        case .atRisk: .atRisk
        case .closed: .closed
        }
    }

    func emptyState(searchText: String, hasAnyPeople: Bool) -> PeopleEmptyState {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !query.isEmpty {
            return PeopleEmptyState(
                title: "No matching people",
                systemImage: "magnifyingglass",
                description: "No \(searchScopeLabel) match \"\(query)\". Clear search or switch filters."
            )
        }

        if !hasAnyPeople {
            return PeopleEmptyState(
                title: "No relationships yet",
                systemImage: "person.crop.circle.badge.plus",
                description: "Add someone important so Maraithon can remember context, cadence, and follow-up history."
            )
        }

        switch self {
        case .all:
            return PeopleEmptyState(
                title: "No people match this filter",
                systemImage: "person.2",
                description: "Switch filters or add the relationship Maraithon should remember."
            )
        case .lead:
            return PeopleEmptyState(
                title: "No new relationships",
                systemImage: "person.badge.plus",
                description: "People you are still qualifying appear here once added."
            )
        case .active:
            return PeopleEmptyState(
                title: "No active relationships",
                systemImage: "person.2",
                description: "Relationships that are current and not flagged for care appear here."
            )
        case .atRisk:
            return PeopleEmptyState(
                title: "No relationship follow-ups flagged",
                systemImage: "person.crop.circle.badge.checkmark",
                description: "People will appear here when a cadence, reply, or relationship check-in is ready for review."
            )
        case .closed:
            return PeopleEmptyState(
                title: "No archived relationships",
                systemImage: "archivebox",
                description: "Archived relationships appear here when you no longer need them active."
            )
        }
    }

    private var searchScopeLabel: String {
        switch self {
        case .all: "people"
        case .lead: "new relationships"
        case .active: "active relationships"
        case .atRisk: "relationships needing care"
        case .closed: "archived people"
        }
    }
}

struct PeopleEmptyState: Equatable {
    let title: String
    let systemImage: String
    let description: String
}

struct CRMStatusCounts: Equatable {
    let all: Int
    let lead: Int
    let active: Int
    let atRisk: Int
    let closed: Int

    func value(for filter: CRMStatusFilter) -> Int {
        switch filter {
        case .all: all
        case .lead: lead
        case .active: active
        case .atRisk: atRisk
        case .closed: closed
        }
    }
}

enum CRMFiltering {
    static func counts(
        _ contacts: [CRMContact],
        searchText: String = "",
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> CRMStatusCounts {
        CRMStatusCounts(
            all: filter(contacts, statusFilter: .all, searchText: searchText, now: now, calendar: calendar).count,
            lead: filter(contacts, statusFilter: .lead, searchText: searchText, now: now, calendar: calendar).count,
            active: filter(contacts, statusFilter: .active, searchText: searchText, now: now, calendar: calendar).count,
            atRisk: filter(contacts, statusFilter: .atRisk, searchText: searchText, now: now, calendar: calendar).count,
            closed: filter(contacts, statusFilter: .closed, searchText: searchText, now: now, calendar: calendar).count
        )
    }

    static func filter(
        _ contacts: [CRMContact],
        statusFilter: CRMStatusFilter,
        searchText: String = "",
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [CRMContact] {
        contacts.filter { contact in
            if !matchesStatus(contact, statusFilter: statusFilter, now: now, calendar: calendar) {
                return false
            }
            return matchesSearch(contact, searchText: searchText)
        }
    }

    static func needsCare(
        _ contact: CRMContact,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard !isArchived(contact) else { return false }
        let level = RelationshipCareSignal.summary(for: contact, now: now, calendar: calendar).level
        return level == .due || level == .needsCare
    }

    static func isArchived(_ contact: CRMContact) -> Bool {
        contact.status == .closed || contact.dealStage == .lost
    }

    private static func matchesStatus(
        _ contact: CRMContact,
        statusFilter: CRMStatusFilter,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        switch statusFilter {
        case .all:
            return true
        case .lead:
            return contact.status == .lead && !isArchived(contact)
        case .active:
            return contact.status == .active && !isArchived(contact) && !needsCare(contact, now: now, calendar: calendar)
        case .atRisk:
            return needsCare(contact, now: now, calendar: calendar)
        case .closed:
            return isArchived(contact)
        }
    }

    private static func matchesSearch(_ contact: CRMContact, searchText: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }

        let searchableValues = [
            contact.name,
            contact.company,
            contact.email,
            contact.phone,
            contact.status.title,
            contact.dealStage.title,
            contact.notes
        ]

        return searchableValues.contains { value in
            value.lowercased().contains(query)
        }
    }
}
