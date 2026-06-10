import Foundation
import SwiftData

@MainActor
enum ProductionDataSync {
    private static let todoPageSize = 500

    static func refreshAll(
        sessionStore: SessionStore,
        modelContext: ModelContext,
        includeCards: Bool = true
    ) async throws {
        try await refreshPeople(sessionStore: sessionStore, modelContext: modelContext)
        try await refreshTodos(
            sessionStore: sessionStore,
            modelContext: modelContext,
            includeCards: includeCards
        )
    }

    static func refreshTodos(
        sessionStore: SessionStore,
        modelContext: ModelContext,
        includeCards: Bool = true
    ) async throws {
        guard let sessionToken = sessionStore.user?.sessionToken else { return }
        let remoteTodos = try await MobileAPIClient().listTodos(
            sessionToken: sessionToken,
            includeCards: includeCards
        )
        let localTodos = try modelContext.fetch(FetchDescriptor<TodoItem>())
        let localByID = Dictionary(uniqueKeysWithValues: localTodos.map { ($0.id, $0) })
        let localContacts = try modelContext.fetch(FetchDescriptor<CRMContact>())
        let contactsByID = Dictionary(uniqueKeysWithValues: localContacts.map { ($0.id, $0) })
        var seenRemoteIDs = Set<UUID>()

        for remoteTodo in remoteTodos {
            guard let id = UUID(uuidString: remoteTodo.id) else { continue }
            seenRemoteIDs.insert(id)

            guard shouldKeepRemoteTodo(remoteTodo) else {
                if let todo = localByID[id] {
                    modelContext.delete(todo)
                }
                continue
            }

            if let todo = localByID[id] {
                apply(remoteTodo, to: todo, includeCards: includeCards, contactsByID: contactsByID)
            } else {
                modelContext.insert(todo(from: remoteTodo, id: id, contactsByID: contactsByID))
            }
        }

        if remoteTodos.count < todoPageSize {
            for todo in localTodos where !seenRemoteIDs.contains(todo.id) {
                modelContext.delete(todo)
            }
        }

        try modelContext.save()
    }

    static func refreshPeople(sessionStore: SessionStore, modelContext: ModelContext) async throws {
        guard let sessionToken = sessionStore.user?.sessionToken else { return }
        let remotePeople = try await MobileAPIClient().listPeople(sessionToken: sessionToken)
        let localContacts = try modelContext.fetch(FetchDescriptor<CRMContact>())
        let localByID = Dictionary(uniqueKeysWithValues: localContacts.map { ($0.id, $0) })

        for remotePerson in remotePeople {
            guard let id = UUID(uuidString: remotePerson.id) else { continue }
            if let contact = localByID[id] {
                apply(remotePerson, to: contact)
            } else {
                modelContext.insert(contact(from: remotePerson, id: id))
            }
        }

        try modelContext.save()
    }

    static func apply(
        _ remoteTodo: MobileAPIClient.RemoteTodo,
        to todo: TodoItem,
        includeCards: Bool = true,
        contactsByID: [UUID: CRMContact]? = nil
    ) {
        todo.title = remoteTodo.title
        todo.notes = remoteTodo.notes ?? remoteTodo.summary ?? ""
        todo.nextAction = remoteTodo.nextAction
        todo.priority = priority(from: remoteTodo.priority)
        todo.dueDate = remoteTodo.dueAt
        todo.isCompleted = remoteTodo.status == "done"
        todo.completedAt = remoteTodo.closedAt
        if let contactsByID {
            todo.contact = relatedContact(for: remoteTodo, contactsByID: contactsByID)
        }
        todo.sourceSystem = cleanedText(remoteTodo.source)
        // A cards-omitted refresh must not wipe existing decision-card context; those
        // fields are filled by the background card pass.
        if includeCards {
            apply(remoteTodo.actionCard, to: todo)
        }
    }

    static func apply(_ remotePerson: MobileAPIClient.RemotePerson, to contact: CRMContact) {
        contact.name = remotePerson.displayName
        contact.company = company(from: remotePerson)
        contact.email = firstContactValue(remotePerson.contactDetails, key: "emails") ?? ""
        contact.phone = firstContactValue(remotePerson.contactDetails, key: "phones") ?? ""
        contact.status = status(from: remotePerson)
        contact.dealStage = dealStage(from: remotePerson)
        contact.dealValue = remotePerson.metadata["deal_value"]?.decimal ?? 0
        contact.lastContactedAt = remotePerson.lastInteractionAt
        contact.notes = remotePerson.notes ?? ""
    }

    static func todoPayload(
        title: String,
        notes: String,
        priority: TodoPriority,
        dueDate: Date?,
        isCompleted: Bool,
        nextAction: String? = nil,
        relatedPersonID: UUID? = nil
    ) -> MobileAPIClient.RequestBody {
        let nextAction = cleanedText(nextAction) ?? cleanedText(title) ?? cleanedText(notes) ?? "Review this item."

        var payload: MobileAPIClient.RequestBody = [
            "source": .string("mobile"),
            "kind": .string("general"),
            "title": .string(title),
            "summary": .string(notes.isEmpty ? title : notes),
            "next_action": .string(nextAction),
            "notes": .string(notes),
            "priority": .int(priorityValue(from: priority)),
            "status": .string(isCompleted ? "done" : "open")
        ]

        if let dueDate {
            payload["due_at"] = .string(isoString(for: dueDate))
        }

        if let relatedPersonID {
            payload["person_id"] = .string(relatedPersonID.uuidString.lowercased())
        }

        return payload
    }

    static func nextActionForTodoPayload(
        title: String,
        notes: String,
        requestedNextAction: String? = nil,
        existingTitle: String? = nil,
        existingNotes: String? = nil,
        existingNextAction: String? = nil
    ) -> String {
        if let requestedNextAction = cleanedText(requestedNextAction) {
            return requestedNextAction
        }

        if let existingNextAction = cleanedText(existingNextAction),
           !sameText(existingNextAction, existingTitle),
           !sameText(existingNextAction, existingNotes) {
            return existingNextAction
        }

        return cleanedText(title) ?? cleanedText(notes) ?? "Review this item."
    }

    static func personPayload(
        name: String,
        company: String,
        email: String,
        phone: String,
        status: ContactStatus,
        dealStage: DealStage,
        dealValue: Decimal,
        notes: String,
        lastContactedAt: Date? = nil
    ) -> MobileAPIClient.RequestBody {
        let relationship = company.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload: MobileAPIClient.RequestBody = [
            "display_name": .string(name),
            "relationship": .string(relationship.isEmpty ? "Personal" : relationship),
            "email": .string(email),
            "notes": .string(notes),
            "metadata": .object([
                "mobile_status": .string(status.rawValue),
                "deal_stage": .string(dealStage.rawValue),
                "deal_value": .string(NSDecimalNumber(decimal: dealValue).stringValue)
            ])
        ]

        if !phone.isEmpty {
            payload["phone"] = .string(phone)
        }

        if let lastContactedAt {
            payload["last_interaction_at"] = .string(isoString(for: lastContactedAt))
        }

        return payload
    }

    static func personPayload(from contact: CRMContact) -> MobileAPIClient.RequestBody {
        personPayload(
            name: contact.name,
            company: contact.company,
            email: contact.email,
            phone: contact.phone,
            status: contact.status,
            dealStage: contact.dealStage,
            dealValue: contact.dealValue,
            notes: contact.notes,
            lastContactedAt: contact.lastContactedAt
        )
    }

    static func shouldKeepRemoteTodo(_ remoteTodo: MobileAPIClient.RemoteTodo) -> Bool {
        remoteTodo.status != "dismissed"
    }

    static func todo(
        from remoteTodo: MobileAPIClient.RemoteTodo,
        id: UUID,
        contactsByID: [UUID: CRMContact]? = nil
    ) -> TodoItem {
        TodoItem(
            id: id,
            title: remoteTodo.title,
            notes: remoteTodo.notes ?? remoteTodo.summary ?? "",
            nextAction: remoteTodo.nextAction,
            priority: priority(from: remoteTodo.priority),
            dueDate: remoteTodo.dueAt,
            isCompleted: remoteTodo.status == "done",
            completedAt: remoteTodo.closedAt,
            decisionPrompt: cleanedText(remoteTodo.actionCard?.decisionPrompt),
            decisionContextSummary: actionCardContextSummary(remoteTodo.actionCard),
            whyNow: cleanedText(remoteTodo.actionCard?.whyNow),
            sourceContext: cleanedText(remoteTodo.actionCard?.sourceContext),
            nextBestAction: cleanedText(remoteTodo.actionCard?.nextBestAction),
            draftPreview: cleanedText(remoteTodo.actionCard?.draftPreview),
            evidenceExcerpt: cleanedText(remoteTodo.actionCard?.evidenceExcerpt),
            sourceSystem: cleanedText(remoteTodo.source),
            sourceProvider: cleanedText(remoteTodo.actionCard?.sourceAction?.provider),
            sourceProviderLabel: cleanedText(remoteTodo.actionCard?.sourceAction?.providerLabel),
            sourceOpenURLString: cleanedText(remoteTodo.actionCard?.sourceAction?.openURL),
            sourceOpenLabel: cleanedText(remoteTodo.actionCard?.sourceAction?.openLabel),
            draftText: cleanedText(remoteTodo.actionCard?.sourceAction?.draftText),
            draftKind: cleanedText(remoteTodo.actionCard?.sourceAction?.draftKind),
            draftRecipient: cleanedText(remoteTodo.actionCard?.sourceAction?.recipient),
            draftRecipientHandle: cleanedText(remoteTodo.actionCard?.sourceAction?.recipientHandle),
            contact: contactsByID.flatMap { relatedContact(for: remoteTodo, contactsByID: $0) }
        )
    }

    private static func apply(_ actionCard: MobileAPIClient.RemoteActionCard?, to todo: TodoItem) {
        todo.decisionPrompt = cleanedText(actionCard?.decisionPrompt)
        todo.decisionContextSummary = actionCardContextSummary(actionCard)
        todo.whyNow = cleanedText(actionCard?.whyNow)
        todo.sourceContext = cleanedText(actionCard?.sourceContext)
        todo.nextBestAction = cleanedText(actionCard?.nextBestAction)
        todo.draftPreview = cleanedText(actionCard?.draftPreview)
        todo.evidenceExcerpt = cleanedText(actionCard?.evidenceExcerpt)
        todo.sourceProvider = cleanedText(actionCard?.sourceAction?.provider)
        todo.sourceProviderLabel = cleanedText(actionCard?.sourceAction?.providerLabel)
        todo.sourceOpenURLString = cleanedText(actionCard?.sourceAction?.openURL)
        todo.sourceOpenLabel = cleanedText(actionCard?.sourceAction?.openLabel)
        todo.draftText = cleanedText(actionCard?.sourceAction?.draftText)
        todo.draftKind = cleanedText(actionCard?.sourceAction?.draftKind)
        todo.draftRecipient = cleanedText(actionCard?.sourceAction?.recipient)
        todo.draftRecipientHandle = cleanedText(actionCard?.sourceAction?.recipientHandle)
    }

    static func contact(from remotePerson: MobileAPIClient.RemotePerson, id: UUID) -> CRMContact {
        CRMContact(
            id: id,
            name: remotePerson.displayName,
            company: company(from: remotePerson),
            email: firstContactValue(remotePerson.contactDetails, key: "emails") ?? "",
            phone: firstContactValue(remotePerson.contactDetails, key: "phones") ?? "",
            status: status(from: remotePerson),
            dealValue: remotePerson.metadata["deal_value"]?.decimal ?? 0,
            dealStage: dealStage(from: remotePerson),
            lastContactedAt: remotePerson.lastInteractionAt,
            notes: remotePerson.notes ?? ""
        )
    }

    private static func priority(from value: Int?) -> TodoPriority {
        switch value ?? 50 {
        case 90...: .critical
        case 75..<90: .high
        case 50..<75: .medium
        default: .low
        }
    }

    private static func priorityValue(from priority: TodoPriority) -> Int {
        switch priority {
        case .critical: 95
        case .high: 80
        case .medium: 55
        case .low: 20
        }
    }

    private static func status(from remotePerson: MobileAPIClient.RemotePerson) -> ContactStatus {
        switch remotePerson.status {
        case "archived", "merged":
            return .closed
        default:
            break
        }

        if let mobileStatus = remotePerson.metadata["mobile_status"]?.string,
           let status = ContactStatus(rawValue: mobileStatus) {
            return status
        }

        return .active
    }

    private static func dealStage(from remotePerson: MobileAPIClient.RemotePerson) -> DealStage {
        if let value = remotePerson.metadata["deal_stage"]?.string,
           let stage = DealStage(rawValue: value) {
            return stage
        }
        return .prospect
    }

    private static func company(from remotePerson: MobileAPIClient.RemotePerson) -> String {
        let relationship = remotePerson.relationship?.trimmingCharacters(in: .whitespacesAndNewlines)
        return relationship?.isEmpty == false ? relationship! : ""
    }

    private static func firstContactValue(_ values: [String: [String]], key: String) -> String? {
        values[key]?.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func relatedContact(
        for remoteTodo: MobileAPIClient.RemoteTodo,
        contactsByID: [UUID: CRMContact]
    ) -> CRMContact? {
        remoteTodo.relatedPeople.lazy.compactMap { relatedPerson in
            UUID(uuidString: relatedPerson.id).flatMap { contactsByID[$0] }
        }.first
    }

    private static func isoString(for date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: false).format(date)
    }

    private static func cleanedText(_ value: String?) -> String? {
        ChiefOfStaffCopy.clean(value)
    }

    private static func actionCardContextSummary(_ actionCard: MobileAPIClient.RemoteActionCard?) -> String? {
        guard let actionCard else { return nil }

        let values = actionCard.contextItems.compactMap { item in
            cleanedText(item.value)
        }

        guard !values.isEmpty else { return nil }

        let uniqueValues = values.reduce(into: [String]()) { result, value in
            let duplicate = result.contains { existing in
                existing.compare(value, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            if !duplicate {
                result.append(value)
            }
        }

        return uniqueValues.joined(separator: " · ")
    }

    private static func sameText(_ lhs: String, _ rhs: String?) -> Bool {
        guard let rhs = cleanedText(rhs) else { return false }
        return lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}
