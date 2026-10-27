import Foundation
import Testing
@testable import MaraithonMobile

@Suite("CRM Quick Actions")
struct CRMQuickActionTests {
    @Test
    func contactLoggedClearsNeedsCareAndRecordsDate() {
        let date = Date(timeIntervalSince1970: 1_779_800_000)
        let contact = CRMContact(
            name: "Ada Chen",
            company: "Northstar",
            email: "ada@example.com",
            status: .atRisk,
            dealStage: .proposal
        )

        CRMQuickAction.logContact(date).apply(to: contact)

        #expect(contact.status == .active)
        #expect(contact.dealStage == .proposal)
        #expect(contact.lastContactedAt == date)
    }

    @Test
    func activeActionUnarchivesLostRelationships() {
        let contact = CRMContact(
            name: "Ada Chen",
            company: "Northstar",
            email: "ada@example.com",
            status: .closed,
            dealStage: .lost
        )

        CRMQuickAction.markActive.apply(to: contact)

        #expect(contact.status == .active)
        #expect(contact.dealStage == .qualified)
    }

    @Test
    func archiveActionMovesPersonOutOfActiveViews() {
        let contact = CRMContact(
            name: "Ada Chen",
            company: "Northstar",
            email: "ada@example.com",
            status: .active,
            dealStage: .proposal
        )

        CRMQuickAction.archive.apply(to: contact)

        #expect(contact.status == .closed)
        #expect(contact.dealStage == .lost)
    }

    @Test
    func snapshotRestoresFailedOptimisticAction() {
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let contact = CRMContact(
            name: "Ada Chen",
            company: "Northstar",
            email: "ada@example.com",
            status: .atRisk,
            dealStage: .proposal,
            lastContactedAt: oldDate
        )
        let snapshot = CRMContactSnapshot(contact: contact)

        CRMQuickAction.archive.apply(to: contact)
        snapshot.restore(to: contact)

        #expect(contact.status == .atRisk)
        #expect(contact.dealStage == .proposal)
        #expect(contact.lastContactedAt == oldDate)
    }
}
