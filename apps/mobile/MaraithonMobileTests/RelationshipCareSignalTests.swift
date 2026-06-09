import Foundation
import Testing
@testable import MaraithonMobile

@Suite("Relationship Care Signal")
struct RelationshipCareSignalTests {
    @Test
    func summaryPrioritizesArchivedAtRiskNewDueAndWarmStates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let archived = CRMContact(
            name: "Archived",
            company: "",
            email: "archived@example.com",
            status: .closed,
            dealStage: .lost
        )
        let atRisk = CRMContact(
            name: "At Risk",
            company: "",
            email: "risk@example.com",
            status: .atRisk,
            lastContactedAt: calendar.date(byAdding: .day, value: -2, to: now)
        )
        let new = CRMContact(name: "New", company: "", email: "new@example.com")
        let due = CRMContact(
            name: "Due",
            company: "",
            email: "due@example.com",
            status: .active,
            lastContactedAt: calendar.date(byAdding: .day, value: -8, to: now)
        )
        let warm = CRMContact(
            name: "Warm",
            company: "",
            email: "warm@example.com",
            status: .active,
            lastContactedAt: calendar.date(byAdding: .day, value: -2, to: now)
        )

        #expect(RelationshipCareSignal.summary(for: archived, now: now, calendar: calendar).level == .archived)
        #expect(RelationshipCareSignal.summary(for: atRisk, now: now, calendar: calendar).level == .needsCare)
        #expect(RelationshipCareSignal.summary(for: new, now: now, calendar: calendar).level == .new)
        #expect(RelationshipCareSignal.summary(for: due, now: now, calendar: calendar).level == .due)
        #expect(RelationshipCareSignal.summary(for: warm, now: now, calendar: calendar).level == .warm)
    }

    @Test
    func staleActiveRelationshipNeedsCareAfterTwoWeeks() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = CRMContact(
            name: "Stale",
            company: "",
            email: "stale@example.com",
            status: .active,
            lastContactedAt: calendar.date(byAdding: .day, value: -15, to: now)
        )

        let summary = RelationshipCareSignal.summary(for: stale, now: now, calendar: calendar)

        #expect(summary.level == .needsCare)
        #expect(summary.actionTitle == "Follow up")
    }

    @Test
    func relationshipCareCopyUsesSentenceCaseActions() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let new = CRMContact(name: "New", company: "", email: "new@example.com")
        let due = CRMContact(
            name: "Due",
            company: "",
            email: "due@example.com",
            status: .active,
            lastContactedAt: calendar.date(byAdding: .day, value: -8, to: now)
        )

        let newSummary = RelationshipCareSignal.summary(for: new, now: now, calendar: calendar)
        let dueSummary = RelationshipCareSignal.summary(for: due, now: now, calendar: calendar)

        #expect(newSummary.actionTitle == "Log contact")
        #expect(dueSummary.title == "Check-in due")
        #expect(dueSummary.actionTitle == "Check in")
        #expect(newSummary.actionTitle != "Log Contact")
        #expect(dueSummary.actionTitle != "Check In")
    }
}
