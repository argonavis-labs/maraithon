import Foundation

struct TodayMetrics: Equatable {
    let openTodos: Int
    let decisionTodos: Int
    let dueTodayTodos: Int
    let overdueTodos: Int
    let peopleCount: Int
    let atRiskContacts: Int
}

enum TodayDestination: Equatable {
    case todos(TodoFilter)
    case people(CRMStatusFilter)
    case chat
}

struct TodayBrief: Equatable {
    let title: String
    let subtitle: String
    let actionTitle: String
    let systemImage: String
    let destination: TodayDestination
}

struct TodayFocusItem: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case todo
        case contact
    }

    let kind: Kind
    let referenceID: UUID
    let title: String
    let subtitle: String
    let detail: String?
    let systemImage: String
    let priority: Int

    var id: String {
        "\(kind.rawValue)-\(referenceID.uuidString)"
    }
}

private struct TodayFocusCandidate {
    let title: String
    let priority: Int
    let item: () -> TodayFocusItem
}

enum TodayInsightEngine {
    static func metrics(
        todos: [TodoItem],
        contacts: [CRMContact],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TodayMetrics {
        TodayMetrics(
            openTodos: todos.filter { !$0.isCompleted }.count,
            decisionTodos: TodoFiltering.filter(todos, by: .decisions, now: now, calendar: calendar).count,
            dueTodayTodos: TodoFiltering.filter(todos, by: .today, now: now, calendar: calendar).count,
            overdueTodos: TodoFiltering.overdueCount(in: todos, now: now, calendar: calendar),
            peopleCount: contacts.count,
            atRiskContacts: CRMFiltering.filter(contacts, statusFilter: .atRisk, now: now, calendar: calendar).count
        )
    }

    static func brief(
        todos: [TodoItem],
        contacts: [CRMContact],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TodayBrief {
        let metrics = metrics(todos: todos, contacts: contacts, now: now, calendar: calendar)
        let overdueTodos = TodoFiltering.filter(todos, by: .overdue, now: now, calendar: calendar)
        let decisionTodos = TodoFiltering.filter(todos, by: .decisions, now: now, calendar: calendar)
        let dueTodayTodos = TodoFiltering.filter(todos, by: .today, now: now, calendar: calendar)
        let atRiskContacts = CRMFiltering.filter(
            contacts,
            statusFilter: .atRisk,
            now: now,
            calendar: calendar
        )
        let openTodos = TodoFiltering.filter(todos, by: .open, now: now, calendar: calendar)

        if metrics.overdueTodos > 0 {
            return TodayBrief(
                title: "Resolve past-due work",
                subtitle: overdueBriefSubtitle(
                    count: metrics.overdueTodos,
                    lead: topTodo(overdueTodos)
                ),
                actionTitle: "Review past-due work",
                systemImage: "clock.badge.exclamationmark",
                destination: .todos(.overdue)
            )
        }

        if metrics.decisionTodos > 0 {
            return TodayBrief(
                title: "Make the calls waiting on you",
                subtitle: decisionBriefSubtitle(
                    count: metrics.decisionTodos,
                    lead: topTodo(decisionTodos)
                ),
                actionTitle: "Review decisions",
                systemImage: "checkmark.seal",
                destination: .todos(.decisions)
            )
        }

        if metrics.dueTodayTodos > 0 {
            return TodayBrief(
                title: "Handle today's commitments",
                subtitle: dueTodayBriefSubtitle(
                    count: metrics.dueTodayTodos,
                    lead: topTodo(dueTodayTodos)
                ),
                actionTitle: "Review today's work",
                systemImage: "calendar.badge.clock",
                destination: .todos(.today)
            )
        }

        if metrics.atRiskContacts > 0 {
            return TodayBrief(
                title: "Relationship follow-ups",
                subtitle: relationshipBriefSubtitle(
                    count: metrics.atRiskContacts,
                    lead: topRelationship(atRiskContacts)
                ),
                actionTitle: "Review people",
                systemImage: "person.crop.circle.badge.exclamationmark",
                destination: .people(.atRisk)
            )
        }

        if metrics.openTodos > 0 {
            return TodayBrief(
                title: "Triage open work",
                subtitle: openWorkBriefSubtitle(
                    count: metrics.openTodos,
                    lead: topTodo(openTodos)
                ),
                actionTitle: "Review open work",
                systemImage: "tray.full",
                destination: .todos(.open)
            )
        }

        return TodayBrief(
            title: "Nothing needs your review right now",
            subtitle: "No saved decision, deadline, or relationship follow-up is waiting. Ask Maraithon for a fresh priority call, draft, or summary when you need one.",
            actionTitle: "Start a review",
            systemImage: "sparkles",
            destination: .chat
        )
    }

    static func focusQueue(
        todos: [TodoItem],
        contacts: [CRMContact],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [TodayFocusItem] {
        let todoItems = todos.compactMap { todo -> TodayFocusCandidate? in
            guard !todo.isCompleted else { return nil }

            if let dueDate = todo.dueDate,
               dueDate < now,
               !calendar.isDate(dueDate, inSameDayAs: now) {
                let priority = 100 + priorityWeight(for: todo.priority)
                return TodayFocusCandidate(title: todo.title, priority: priority) {
                    TodayFocusItem(
                        kind: .todo,
                        referenceID: todo.id,
                        title: todo.title,
                        subtitle: todoFocusSubtitle(
                            for: todo,
                            fallbackAction: "Handle, move, or dismiss it."
                        ),
                        detail: todoFocusDetail(
                            for: todo,
                            context: overdueFocusContext(for: todo, dueDate: dueDate, now: now, calendar: calendar)
                        ),
                        systemImage: "clock.badge.exclamationmark",
                        priority: priority
                    )
                }
            }

            if TodoDecisionSignals.needsDecision(todo) {
                let priority = 88 + priorityWeight(for: todo.priority)
                return TodayFocusCandidate(title: todo.title, priority: priority) {
                    TodayFocusItem(
                        kind: .todo,
                        referenceID: todo.id,
                        title: todo.title,
                        subtitle: todoFocusSubtitle(
                            for: todo,
                            fallbackAction: "Make the call, delegate it, or dismiss it."
                        ),
                        detail: todoFocusDetail(
                            for: todo,
                            context: decisionFocusContext(for: todo, now: now, calendar: calendar)
                        ),
                        systemImage: "checkmark.seal",
                        priority: priority
                    )
                }
            }

            if let dueDate = todo.dueDate,
               calendar.isDate(dueDate, inSameDayAs: now) {
                let priority = 80 + priorityWeight(for: todo.priority)
                return TodayFocusCandidate(title: todo.title, priority: priority) {
                    TodayFocusItem(
                        kind: .todo,
                        referenceID: todo.id,
                        title: todo.title,
                        subtitle: todoFocusSubtitle(
                            for: todo,
                            fallbackAction: "Finish, move, or reschedule it before tomorrow."
                        ),
                        detail: todoFocusDetail(for: todo, context: "Due today"),
                        systemImage: todo.priority.symbolName,
                        priority: priority
                    )
                }
            }

            if todo.priority == .critical || todo.priority == .high {
                let priority = todo.priority == .critical ? 85 : 65
                return TodayFocusCandidate(title: todo.title, priority: priority) {
                    TodayFocusItem(
                        kind: .todo,
                        referenceID: todo.id,
                        title: todo.title,
                        subtitle: todoFocusSubtitle(
                            for: todo,
                            fallbackAction: "Decide, delegate, or schedule a concrete next move."
                        ),
                        detail: todoFocusDetail(for: todo, context: "\(todo.priority.title) priority"),
                        systemImage: todo.priority.symbolName,
                        priority: priority
                    )
                }
            }

            return nil
        }

        let contactItems = contacts.compactMap { contact -> TodayFocusCandidate? in
            guard !CRMFiltering.isArchived(contact) else { return nil }

            if isAtRisk(contact, now: now, calendar: calendar) {
                return TodayFocusCandidate(title: contact.name, priority: 75) {
                    TodayFocusItem(
                        kind: .contact,
                        referenceID: contact.id,
                        title: contact.name,
                        subtitle: "Next: Follow up with \(relationshipContext(for: contact))",
                        detail: relationshipDetail(for: contact, now: now),
                        systemImage: "person.crop.circle.badge.exclamationmark",
                        priority: 75
                    )
                }
            }

            if contact.dealStage == .proposal,
               isStale(contact, now: now, calendar: calendar) {
                return TodayFocusCandidate(title: contact.name, priority: 60) {
                    TodayFocusItem(
                        kind: .contact,
                        referenceID: contact.id,
                        title: contact.name,
                        subtitle: "Next: Follow up with \(relationshipContext(for: contact))",
                        detail: relationshipDetail(for: contact, now: now),
                        systemImage: "person.wave.2",
                        priority: 60
                    )
                }
            }

            return nil
        }

        return (todoItems + contactItems)
            .sorted {
                if $0.priority == $1.priority {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                } else {
                    $0.priority > $1.priority
                }
            }
            .prefix(6)
            .map { $0.item() }
    }

    static func isAtRisk(
        _ contact: CRMContact,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        CRMFiltering.needsCare(contact, now: now, calendar: calendar)
    }

    static func isStale(
        _ contact: CRMContact,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard let lastContactedAt = contact.lastContactedAt else { return true }
        guard let threshold = calendar.date(byAdding: .day, value: -7, to: now) else {
            return false
        }
        return lastContactedAt < threshold
    }

    private static func priorityWeight(for priority: TodoPriority) -> Int {
        switch priority {
        case .critical: 25
        case .high: 15
        case .medium: 8
        case .low: 0
        }
    }

    private static func overdueBriefSubtitle(count: Int, lead: TodoItem?) -> String {
        guard let title = briefTitle(for: lead) else {
            return "\(count) past-due \(plural("work item", count)) \(needsVerb(count)) a decision. Handle, move, or dismiss \(objectPronoun(count))."
        }

        if count == 1 {
            return "\(title) is past due. \(briefMove(for: lead) ?? "Handle, move, or dismiss it.")"
        }

        if let move = briefMove(for: lead) {
            return "\(count) past-due work items need a decision. Start with \(title): \(move)"
        }

        return "\(count) past-due work items need a decision. Start with \(title)."
    }

    private static func dueTodayBriefSubtitle(count: Int, lead: TodoItem?) -> String {
        guard let title = briefTitle(for: lead) else {
            return "\(count) \(plural("work item", count)) \(isVerb(count)) due today."
        }

        if count == 1 {
            return "\(title) is due today. \(briefMove(for: lead) ?? "Move it before tomorrow or reschedule it.")"
        }

        if let move = briefMove(for: lead) {
            return "\(count) work items are due today. Start with \(title): \(move)"
        }

        return "\(count) work items are due today. Start with \(title)."
    }

    private static func decisionBriefSubtitle(count: Int, lead: TodoItem?) -> String {
        guard let title = briefTitle(for: lead) else {
            return "\(count) \(plural("decision", count)) \(needsVerb(count)) a call, approval, or keep-or-close choice."
        }

        if count == 1 {
            return "Decision needed: \(title). \(briefMove(for: lead) ?? "Make the call, delegate it, or dismiss it.")"
        }

        if let move = briefMove(for: lead) {
            return "\(count) decisions are waiting. Start with \(title): \(move)"
        }

        return "\(count) decisions are waiting. Start with \(title)."
    }

    private static func relationshipBriefSubtitle(count: Int, lead: CRMContact?) -> String {
        guard let subject = relationshipBriefSubject(for: lead) else {
            return "\(count) \(plural("person", count, plural: "people")) \(needsVerb(count)) a follow-up or status update."
        }

        if count == 1 {
            return "\(subject) needs a follow-up or status update."
        }

        return "\(count) relationships need attention. Start with \(subject)."
    }

    private static func openWorkBriefSubtitle(count: Int, lead: TodoItem?) -> String {
        guard let title = briefTitle(for: lead) else {
            return "\(count) open \(plural("work item", count)) \(needsVerb(count)) a date, next action, or close decision."
        }

        if count == 1 {
            return "\(title) needs a date, next action, or close decision."
        }

        if let move = briefMove(for: lead) {
            return "\(count) open work items need triage. Start with \(title): \(move)"
        }

        return "\(count) open work items need triage. Start with \(title)."
    }

    private static func topTodo(_ todos: [TodoItem]) -> TodoItem? {
        todos.sorted {
            if $0.priority != $1.priority {
                return priorityWeight(for: $0.priority) > priorityWeight(for: $1.priority)
            }

            switch ($0.dueDate, $1.dueDate) {
            case (.some(let lhs), .some(let rhs)) where lhs != rhs:
                return lhs < rhs
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }.first
    }

    private static func topRelationship(_ contacts: [CRMContact]) -> CRMContact? {
        contacts.sorted {
            switch ($0.lastContactedAt, $1.lastContactedAt) {
            case (.none, .some):
                return true
            case (.some, .none):
                return false
            case (.some(let lhs), .some(let rhs)) where lhs != rhs:
                return lhs < rhs
            default:
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }.first
    }

    private static func briefTitle(for todo: TodoItem?) -> String? {
        cleanedText(todo?.title)
    }

    private static func briefMove(for todo: TodoItem?) -> String? {
        let move =
            cleanedText(todo?.nextBestAction) ??
            cleanedText(todo?.displayNextAction) ??
            cleanedText(todo?.decisionPrompt)

        return move.map(sentence)
    }

    private static func relationshipBriefSubject(for contact: CRMContact?) -> String? {
        guard let contact else { return nil }
        let name = cleanedText(contact.name)
        let company = cleanedText(contact.company)

        switch (name, company) {
        case (.some(let name), .some(let company)):
            return "\(name) at \(company)"
        case (.some(let name), .none):
            return name
        case (.none, .some(let company)):
            return company
        default:
            return nil
        }
    }

    private static func todoFocusSubtitle(
        for todo: TodoItem,
        fallbackAction: String
    ) -> String {
        if let decisionPrompt = cleanedText(todo.decisionPrompt) {
            return decisionPrompt
        }

        guard let nextAction = cleanedText(todo.displayNextAction) else {
            return "Next: \(sentence(fallbackAction))"
        }

        return "Next: \(sentence(nextAction))"
    }

    private static func todoFocusDetail(for todo: TodoItem, context: String?) -> String? {
        let decisionContext = TodoDecisionContext(todo: todo)
        let context = cleanedText(context).map(sentence)
        let whyNow = decisionContext.whyNow.map(sentence)
        let evidence = decisionContext.evidence.map { sentence(truncate($0, limit: 140)) }
        let sourceContext = decisionContext.sourceContext

        return [context, whyNow, evidence, sourceContext]
            .compactMap { $0 }
            .joined(separator: " ")
            .nilIfBlank
    }

    private static func decisionFocusContext(
        for todo: TodoItem,
        now: Date,
        calendar: Calendar
    ) -> String {
        if let dueDate = todo.dueDate {
            if dueDate < now, !calendar.isDate(dueDate, inSameDayAs: now) {
                return "Decision waiting. \(dueSubtitle(for: dueDate, now: now))"
            }

            if calendar.isDate(dueDate, inSameDayAs: now) {
                return "Decision waiting. Due today"
            }
        }

        return "Decision waiting"
    }

    private static func overdueFocusContext(
        for todo: TodoItem,
        dueDate: Date,
        now: Date,
        calendar: Calendar
    ) -> String {
        if hasExplicitDecisionCard(todo) {
            return decisionFocusContext(for: todo, now: now, calendar: calendar)
        }

        return dueSubtitle(for: dueDate, now: now)
    }

    private static func hasExplicitDecisionCard(_ todo: TodoItem) -> Bool {
        let context = TodoDecisionContext(todo: todo)

        if context.decisionPrompt != nil {
            return true
        }

        return context.preparedMove != nil && context.evidence != nil
    }

    private static func relationshipDetail(
        for contact: CRMContact,
        now: Date
    ) -> String? {
        let recency: String
        if let lastContactedAt = contact.lastContactedAt {
            recency = "Last reached out \(AppFormatters.relativeString(for: lastContactedAt, relativeTo: now))"
        } else {
            recency = "No recent contact logged"
        }

        if let notes = cleanedText(contact.notes) {
            return "\(recency). \(notes)"
        }

        return recency
    }

    private static func dueSubtitle(for dueDate: Date, now: Date) -> String {
        "Due \(AppFormatters.relativeString(for: dueDate, relativeTo: now))"
    }

    private static func relationshipContext(for contact: CRMContact) -> String {
        let context = contact.company.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty {
            return context
        }

        let name = contact.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "this person" : name
    }

    private static func plural(_ singular: String, _ count: Int, plural: String? = nil) -> String {
        count == 1 ? singular : (plural ?? "\(singular)s")
    }

    private static func needsVerb(_ count: Int) -> String {
        count == 1 ? "needs" : "need"
    }

    private static func isVerb(_ count: Int) -> String {
        count == 1 ? "is" : "are"
    }

    private static func objectPronoun(_ count: Int) -> String {
        count == 1 ? "it" : "them"
    }

    private static func cleanedText(_ value: String?) -> String? {
        ChiefOfStaffCopy.clean(value)
    }

    private static func sentence(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?") {
            return trimmed
        }
        return "\(trimmed)."
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }

        let index = value.index(value.startIndex, offsetBy: limit)
        return "\(value[..<index].trimmingCharacters(in: .whitespacesAndNewlines))..."
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
