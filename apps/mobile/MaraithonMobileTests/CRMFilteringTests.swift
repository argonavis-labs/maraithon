import Testing
@testable import MaraithonMobile

@Suite("People Filtering")
struct CRMFilteringTests {
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
        let active = CRMContact(
            name: "Ada Chen",
            company: "Acme",
            email: "ada@example.com",
            status: .active
        )
        let atRisk = CRMContact(
            name: "Mason Patel",
            company: "Acme",
            email: "mason@example.com",
            status: .atRisk
        )
        let archived = CRMContact(
            name: "Lena Ortiz",
            company: "Other",
            email: "lena@example.com",
            status: .closed
        )

        let counts = CRMFiltering.counts([active, atRisk, archived], searchText: "acme")

        #expect(counts == CRMStatusCounts(all: 2, lead: 0, active: 1, atRisk: 1, closed: 0))
        #expect(counts.value(for: .atRisk) == CRMFiltering.filter(
            [active, atRisk, archived],
            statusFilter: .atRisk,
            searchText: "acme"
        ).count)
    }
}
