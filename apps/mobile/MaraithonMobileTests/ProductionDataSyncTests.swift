import Foundation
import Testing
@testable import MaraithonMobile

@Suite("Production Data Sync")
@MainActor
struct ProductionDataSyncTests {
    @Test
    func personPayloadUsesPersonalFallbackForEmptyRelationshipContext() {
        let payload = ProductionDataSync.personPayload(
            name: "Alex",
            company: " ",
            email: "alex@example.com",
            phone: "",
            status: .active,
            dealStage: .qualified,
            dealValue: 0,
            notes: ""
        )

        #expect(payload["relationship"] as? String == "Personal")
    }

    @Test
    func personPayloadCanPersistLastContactedAt() {
        let date = Date(timeIntervalSince1970: 1_779_800_000)
        let payload = ProductionDataSync.personPayload(
            name: "Alex",
            company: "Friend",
            email: "alex@example.com",
            phone: "",
            status: .active,
            dealStage: .qualified,
            dealValue: 0,
            notes: "",
            lastContactedAt: date
        )

        #expect(payload["last_interaction_at"] as? String == ISO8601DateFormatter().string(from: date))
    }

    @Test
    func personPayloadFromContactPreservesQuickActionState() {
        let date = Date(timeIntervalSince1970: 1_779_800_000)
        let contact = CRMContact(
            name: "Ada Chen",
            company: "Northstar",
            email: "ada@example.com",
            phone: "555-0100",
            status: .active,
            dealValue: 42_000,
            dealStage: .qualified,
            lastContactedAt: date,
            notes: "Board prep contact."
        )

        let payload = ProductionDataSync.personPayload(from: contact)
        let metadata = payload["metadata"] as? [String: String]

        #expect(payload["display_name"] as? String == "Ada Chen")
        #expect(payload["relationship"] as? String == "Northstar")
        #expect(payload["last_interaction_at"] as? String == ISO8601DateFormatter().string(from: date))
        #expect(metadata?["mobile_status"] == "active")
        #expect(metadata?["deal_stage"] == "qualified")
    }

    @Test
    func serverArchivedRelationshipStateWinsOverStaleMobileMetadata() {
        let archived = ProductionDataSync.contact(
            from: remotePerson(
                status: "archived",
                metadata: ["mobile_status": "active", "deal_stage": "proposal"]
            ),
            id: UUID()
        )
        let merged = ProductionDataSync.contact(
            from: remotePerson(
                status: "merged",
                metadata: ["mobile_status": "active", "deal_stage": "qualified"]
            ),
            id: UUID()
        )

        #expect(archived.status == .closed)
        #expect(archived.dealStage == .proposal)
        #expect(merged.status == .closed)
        #expect(merged.dealStage == .qualified)
    }

    @Test
    func remotePersonWithoutRelationshipContextDoesNotInventCompany() {
        let missingRelationship = ProductionDataSync.contact(
            from: remotePerson(relationship: nil),
            id: UUID()
        )
        let blankRelationship = ProductionDataSync.contact(
            from: remotePerson(relationship: " "),
            id: UUID()
        )

        #expect(missingRelationship.company == "")
        #expect(blankRelationship.company == "")
    }

    @Test
    func dismissedRemoteTodosDoNotReturnToMobileList() {
        #expect(
            ProductionDataSync.shouldKeepRemoteTodo(remoteTodo(status: "open"))
        )
        #expect(
            ProductionDataSync.shouldKeepRemoteTodo(remoteTodo(status: "done"))
        )
        #expect(
            !ProductionDataSync.shouldKeepRemoteTodo(remoteTodo(status: "dismissed"))
        )
    }

    @Test
    func remoteTodoPriorityScoresMapToUrgencyBands() {
        #expect(ProductionDataSync.todo(from: remoteTodo(priority: 95), id: UUID()).priority == .critical)
        #expect(ProductionDataSync.todo(from: remoteTodo(priority: 90), id: UUID()).priority == .critical)
        #expect(ProductionDataSync.todo(from: remoteTodo(priority: 80), id: UUID()).priority == .high)
        #expect(ProductionDataSync.todo(from: remoteTodo(priority: 55), id: UUID()).priority == .medium)
        #expect(ProductionDataSync.todo(from: remoteTodo(priority: 20), id: UUID()).priority == .low)
        #expect(ProductionDataSync.todo(from: remoteTodo(priority: nil), id: UUID()).priority == .medium)
    }

    @Test
    func todoPayloadUsesServerScoresForUrgencyBands() {
        #expect(todoPayloadPriority(.critical) == 95)
        #expect(todoPayloadPriority(.high) == 80)
        #expect(todoPayloadPriority(.medium) == 55)
        #expect(todoPayloadPriority(.low) == 20)
    }

    @Test
    func todoPayloadPreservesExplicitNextActionWhenEditingGeneratedWork() {
        let nextAction = ProductionDataSync.nextActionForTodoPayload(
            title: "Reply to board follow-up",
            notes: "A board member is waiting on the financing packet.",
            requestedNextAction: " ",
            existingTitle: "Board follow-up",
            existingNotes: "A board member asked for the financing packet.",
            existingNextAction: "Send the financing packet and confirm the next review window."
        )

        let payload = ProductionDataSync.todoPayload(
            title: "Reply to board follow-up",
            notes: "A board member is waiting on the financing packet.",
            priority: .high,
            dueDate: nil,
            isCompleted: false,
            nextAction: nextAction
        )

        #expect(payload["next_action"] as? String == "Send the financing packet and confirm the next review window.")
    }

    @Test
    func todoPayloadUsesOperatorEditedNextActionOverExistingGeneratedWork() {
        let nextAction = ProductionDataSync.nextActionForTodoPayload(
            title: "Reply to board follow-up",
            notes: "A board member is waiting on the financing packet.",
            requestedNextAction: "Send the packet, then ask whether Friday still works.",
            existingTitle: "Board follow-up",
            existingNotes: "A board member asked for the financing packet.",
            existingNextAction: "Send the financing packet and confirm the next review window."
        )

        let payload = ProductionDataSync.todoPayload(
            title: "Reply to board follow-up",
            notes: "A board member is waiting on the financing packet.",
            priority: .high,
            dueDate: nil,
            isCompleted: false,
            nextAction: nextAction
        )

        #expect(payload["next_action"] as? String == "Send the packet, then ask whether Friday still works.")
    }

    @Test
    func nextActionForTodoPayloadRefreshesGenericTitleActionAfterManualEdit() {
        let nextAction = ProductionDataSync.nextActionForTodoPayload(
            title: "Send revised investor update",
            notes: "Use the board-approved metrics.",
            requestedNextAction: "",
            existingTitle: "Send investor update",
            existingNotes: "",
            existingNextAction: "Send investor update"
        )

        #expect(nextAction == "Send revised investor update")
    }

    @Test
    func remoteTodoNextActionSurvivesSyncForActionRows() {
        let remote = remoteTodo(
            summary: "The customer asked whether the support plan is ready.",
            nextAction: "Reply with the support plan, owner, and next review date."
        )

        let todo = ProductionDataSync.todo(from: remote, id: UUID())

        #expect(todo.notes == "The customer asked whether the support plan is ready.")
        #expect(todo.nextAction == "Reply with the support plan, owner, and next review date.")
        #expect(todo.displayNextAction == "Reply with the support plan, owner, and next review date.")
    }

    private func todoPayloadPriority(_ priority: TodoPriority) -> Int? {
        ProductionDataSync.todoPayload(
            title: "Send investor update",
            notes: "",
            priority: priority,
            dueDate: nil,
            isCompleted: false
        )["priority"] as? Int
    }

    private func remotePerson(
        status: String = "active",
        relationship: String? = "Northstar",
        metadata: [String: Any] = [:]
    ) -> MobileAPIClient.RemotePerson {
        var payload: [String: Any] = [
            "id": UUID().uuidString,
            "display_name": "Ada Chen",
            "contact_details": ["emails": ["ada@example.com"], "phones": []],
            "status": status,
            "notes": "Board prep contact.",
            "metadata": metadata,
            "last_interaction_at": NSNull()
        ]
        payload["relationship"] = relationship ?? NSNull()
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return try! JSONDecoder().decode(MobileAPIClient.RemotePerson.self, from: data)
    }

    private func remoteTodo(
        status: String = "open",
        priority: Int? = 55,
        summary: String? = nil,
        nextAction: String? = nil
    ) -> MobileAPIClient.RemoteTodo {
        MobileAPIClient.RemoteTodo(
            id: UUID().uuidString,
            title: "Send investor update",
            summary: summary,
            nextAction: nextAction,
            dueAt: nil,
            notes: nil,
            priority: priority,
            status: status,
            closedAt: nil
        )
    }
}
