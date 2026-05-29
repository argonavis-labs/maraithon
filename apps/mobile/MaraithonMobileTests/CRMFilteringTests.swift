import Foundation
import Testing
@testable import MaraithonMobile

@Suite("People Filtering")
struct CRMFilteringTests {
    @Test
    func relationshipViewCopyAvoidsDatabaseAndTimestampLanguage() {
        #expect(ContactDetailCopy.contactDetailsSectionTitle == "Contact details")
        #expect(ContactDetailCopy.relationshipSectionTitle == "Relationship status")
        #expect(ContactDetailCopy.lastContactedLabel == "Last reached out")
        #expect(ContactDetailCopy.logContactSubtitle == "Record that you reached out")
        #expect(ContactDetailCopy.addFollowUpTitle == "Add follow-up")
        #expect(ContactDetailCopy.addFollowUpSubtitle == "Create a linked next move")
        #expect(ContactEditorCopy.contextPlaceholder == "Company, role, or context")
        #expect(ContactEditorCopy.notesPlaceholder == "What matters about this relationship")
        #expect(ContactEditorCopy.newNavigationTitle == "New person")
        #expect(CRMViewCopy.reachedOutActionTitle == "Reached out")
        #expect(CRMViewCopy.addPersonAccessibilityLabel == "Add person")
        #expect(!ContactDetailCopy.visibleLabels.contains("Reach"))
        #expect(!ContactDetailCopy.visibleLabels.contains("Linked Work"))
        #expect(!ContactDetailCopy.visibleLabels.contains("Update the relationship timestamp"))
        #expect(!ContactEditorCopy.visibleLabels.contains("New Person"))
        #expect(!ContactEditorCopy.visibleLabels.contains("Company or context"))
    }

    @Test
    func filtersByStatusAndSearchText() {
        let active = CRMContact(
            name: "Ada Chen",
            company: "Northstar Labs",
            email: "ada@example.com",
            status: .active,
            dealStage: .proposal,
            notes: "Security review"
        )
        let lead = CRMContact(
            name: "Mason Patel",
            company: "Forge Health",
            email: "mason@example.com",
            status: .lead,
            dealStage: .qualified
        )

        let result = CRMFiltering.filter(
            [active, lead],
            statusFilter: .active,
            searchText: "northstar"
        )

        #expect(result.map(\.name) == ["Ada Chen"])
    }

    @Test
    func countsMatchStatusFiltersAndSearchText() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let active = CRMContact(
            name: "Ada Chen",
            company: "Acme",
            email: "ada@example.com",
            status: .active,
            lastContactedAt: now
        )
        let atRisk = CRMContact(
            name: "Mason Patel",
            company: "Acme",
            email: "mason@example.com",
            status: .atRisk
        )
        let staleActive = CRMContact(
            name: "Nora Lee",
            company: "Acme",
            email: "nora@example.com",
            status: .active,
            lastContactedAt: now.addingTimeInterval(-10 * 24 * 60 * 60)
        )
        let lostActive = CRMContact(
            name: "Owen Grant",
            company: "Acme",
            email: "owen@example.com",
            status: .active,
            dealStage: .lost,
            lastContactedAt: now.addingTimeInterval(-20 * 24 * 60 * 60)
        )
        let archived = CRMContact(
            name: "Lena Ortiz",
            company: "Other",
            email: "lena@example.com",
            status: .closed
        )

        let contacts = [active, atRisk, staleActive, lostActive, archived]
        let counts = CRMFiltering.counts(
            contacts,
            searchText: "acme",
            now: now,
            calendar: calendar
        )

        #expect(counts == CRMStatusCounts(all: 4, lead: 0, active: 1, atRisk: 2, closed: 1))
        #expect(counts.value(for: .atRisk) == CRMFiltering.filter(
            contacts,
            statusFilter: .atRisk,
            searchText: "acme",
            now: now,
            calendar: calendar
        ).count)
    }

    @Test
    func needsCareFilterMatchesStaleActiveRelationshipsFromToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let staleActive = CRMContact(
            name: "Ada Chen",
            company: "Northstar",
            email: "ada@example.com",
            status: .active,
            lastContactedAt: now.addingTimeInterval(-10 * 24 * 60 * 60)
        )
        let warmActive = CRMContact(
            name: "Mason Patel",
            company: "Forge",
            email: "mason@example.com",
            status: .active,
            lastContactedAt: now.addingTimeInterval(-2 * 24 * 60 * 60)
        )
        let lostAtRisk = CRMContact(
            name: "Lena Ortiz",
            company: "Archived",
            email: "lena@example.com",
            status: .atRisk,
            dealStage: .lost,
            lastContactedAt: now.addingTimeInterval(-30 * 24 * 60 * 60)
        )

        let result = CRMFiltering.filter(
            [warmActive, lostAtRisk, staleActive],
            statusFilter: .atRisk,
            now: now,
            calendar: calendar
        )

        #expect(result.map(\.name) == ["Ada Chen"])
    }

    @Test
    func emptyStateCopyMatchesSelectedPeopleFilter() {
        #expect(CRMStatusFilter.all.emptyState(searchText: "", hasAnyPeople: false) == PeopleEmptyState(
            title: "No people yet",
            systemImage: "person.crop.circle.badge.plus",
            description: "Add someone important so Maraithon can remember context, cadence, and follow-up history."
        ))

        #expect(CRMStatusFilter.atRisk.emptyState(searchText: "", hasAnyPeople: true) == PeopleEmptyState(
            title: "No relationships need care",
            systemImage: "person.crop.circle.badge.checkmark",
            description: "You are clear on follow-ups and relationship check-ins that need attention."
        ))
        #expect(!CRMStatusFilter.atRisk.emptyState(searchText: "", hasAnyPeople: true)
            .description
            .localizedCaseInsensitiveContains("stale"))

        #expect(CRMStatusFilter.lead.emptyState(searchText: "", hasAnyPeople: true).title == "No new relationships")
        #expect(CRMStatusFilter.active.emptyState(searchText: "", hasAnyPeople: true).title == "No active relationships")
        #expect(CRMStatusFilter.closed.emptyState(searchText: "", hasAnyPeople: true).title == "No archived people")
    }

    @Test
    func emptyStateSearchCopyDoesNotMislabelTheActivePeopleFilter() {
        let state = CRMStatusFilter.atRisk.emptyState(searchText: " board ", hasAnyPeople: true)

        #expect(state.title == "No matching people")
        #expect(state.systemImage == "magnifyingglass")
        #expect(state.description == "No relationships needing care match \"board\". Clear search or switch filters.")
    }
}
