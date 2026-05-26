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
        searchText: String = ""
    ) -> CRMStatusCounts {
        CRMStatusCounts(
            all: filter(contacts, statusFilter: .all, searchText: searchText).count,
            lead: filter(contacts, statusFilter: .lead, searchText: searchText).count,
            active: filter(contacts, statusFilter: .active, searchText: searchText).count,
            atRisk: filter(contacts, statusFilter: .atRisk, searchText: searchText).count,
            closed: filter(contacts, statusFilter: .closed, searchText: searchText).count
        )
    }

    static func filter(
        _ contacts: [CRMContact],
        statusFilter: CRMStatusFilter,
        searchText: String = ""
    ) -> [CRMContact] {
        contacts.filter { contact in
            if let status = statusFilter.status, contact.status != status {
                return false
            }
            return matchesSearch(contact, searchText: searchText)
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
