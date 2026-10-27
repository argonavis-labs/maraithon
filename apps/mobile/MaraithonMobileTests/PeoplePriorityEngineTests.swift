import Foundation
import Testing
@testable import MaraithonMobile

@Suite("People Priority Engine")
@MainActor
struct PeoplePriorityEngineTests {
    @Test
    func suggestedTabPreservesModelSuggestionOrder() throws {
        let alexID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let blairID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let alex = CRMContact(id: alexID, name: "Alex", company: "Northstar", email: "alex@example.com")
        let blair = CRMContact(id: blairID, name: "Blair", company: "Board", email: "blair@example.com")

        let suggestions = [
            try suggestion(personID: blairID, name: "Blair", reason: "Blair has a model-backed follow-up."),
            try suggestion(personID: alexID, name: "Alex", reason: "Alex is going quiet.")
        ]

        let contexts = PeoplePriorityEngine.contexts(
            contacts: [alex, blair],
            todos: [],
            goals: [],
            suggestions: suggestions
        )
        let suggested = PeoplePriorityEngine.contexts(
            for: .suggested,
            contexts: contexts,
            suggestions: suggestions
        )

        #expect(suggested.map(\.contact.id) == [blairID, alexID])
        #expect(PeoplePriorityEngine.counts(from: contexts).suggested == 2)
    }

    @Test
    func goalsTabIncludesOnlyPeopleLinkedToActiveGoals() throws {
        let linkedID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let unlinkedID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let linked = CRMContact(id: linkedID, name: "Casey", company: "Launch", email: "casey@example.com")
        let unlinked = CRMContact(id: unlinkedID, name: "Devin", company: "Archive", email: "devin@example.com")
        let goals = [
            try goal(
                id: "goal-high",
                title: "Ship app review",
                priority: 90,
                status: "active",
                personID: linkedID
            ),
            try goal(
                id: "goal-archived",
                title: "Old initiative",
                priority: 100,
                status: "archived",
                personID: unlinkedID
            )
        ]

        let contexts = PeoplePriorityEngine.contexts(
            contacts: [unlinked, linked],
            todos: [],
            goals: goals,
            suggestions: []
        )
        let goalPeople = PeoplePriorityEngine.contexts(
            for: .goals,
            contexts: contexts,
            suggestions: []
        )

        #expect(goalPeople.map(\.contact.id) == [linkedID])
        #expect(goalPeople.first?.signalLine(for: .goals).contains("Ship app review") == true)
        #expect(PeoplePriorityEngine.counts(from: contexts).goals == 1)
    }

    @Test
    func openWorkTabRanksOverdueHighPriorityWorkFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let urgentID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let normalID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let urgent = CRMContact(id: urgentID, name: "Elliot", company: "Investor", email: "elliot@example.com")
        let normal = CRMContact(id: normalID, name: "Finley", company: "Vendor", email: "finley@example.com")

        let overdue = TodoItem(
            title: "Send the revised packet",
            nextAction: "Send the revised packet and ask for the Friday decision.",
            priority: .high,
            dueDate: calendar.date(byAdding: .day, value: -1, to: now),
            contact: urgent
        )
        let undated = TodoItem(
            title: "Review vendor note",
            priority: .critical,
            contact: normal
        )

        let contexts = PeoplePriorityEngine.contexts(
            contacts: [normal, urgent],
            todos: [undated, overdue],
            goals: [],
            suggestions: [],
            now: now,
            calendar: calendar
        )
        let openWork = PeoplePriorityEngine.contexts(
            for: .openWork,
            contexts: contexts,
            suggestions: [],
            now: now,
            calendar: calendar
        )

        #expect(openWork.map(\.contact.id) == [urgentID, normalID])
        #expect(openWork.first?.signalLine(for: .openWork) == "Send the revised packet and ask for the Friday decision.")
        #expect(PeoplePriorityEngine.counts(from: contexts).openWork == 2)
    }

    private func suggestion(
        personID: UUID,
        name: String,
        reason: String
    ) throws -> MobileAPIClient.RemoteReconnectSuggestion {
        let payload: [String: Any] = [
            "person": [
                "id": personID.uuidString,
                "display_name": name,
                "status": "active",
                "contact_details": ["emails": [], "phones": []],
                "metadata": [:]
            ],
            "category": "open_work",
            "headline": "Open work",
            "reason": reason,
            "suggested_action": "Send a focused follow-up.",
            "days_since_last": NSNull(),
            "cadence_days": NSNull(),
            "communication_score": 80,
            "overdue": false,
            "open_work": []
        ]
        return try decode(MobileAPIClient.RemoteReconnectSuggestion.self, from: payload)
    }

    private func goal(
        id: String,
        title: String,
        priority: Int,
        status: String,
        personID: UUID
    ) throws -> MobileAPIClient.RemoteGoal {
        let payload: [String: Any] = [
            "id": id,
            "category": "work",
            "status": status,
            "title": title,
            "desired_outcome": "Move the outcome forward.",
            "why": "Important relationship.",
            "success_metric": "Clear progress",
            "priority": priority,
            "sensitivity": "standard",
            "proactive_visibility": "summary",
            "review_cadence": "weekly",
            "linked_work_count": 0,
            "linked_people_count": 1,
            "latest_progress": NSNull(),
            "progress_updates": [],
            "links": [
                [
                    "id": "\(id)-link",
                    "goal_id": id,
                    "resource_type": "person",
                    "resource_id": personID.uuidString,
                    "relationship": "supports",
                    "source": "test",
                    "confidence": 0.9,
                    "metadata": [:]
                ]
            ],
            "review_runs": []
        ]
        return try decode(MobileAPIClient.RemoteGoal.self, from: payload)
    }

    private func decode<T: Decodable>(_ type: T.Type, from payload: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(type, from: data)
    }
}
