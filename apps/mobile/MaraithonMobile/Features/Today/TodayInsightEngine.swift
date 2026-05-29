import Foundation

struct TodayMetrics: Equatable {
    let openTodos: Int
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
    let systemImage: String
    let priority: Int

    var id: String {
        "\(kind.rawValue)-\(referenceID.uuidString)"
    }
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

        if metrics.overdueTodos > 0 {
            return TodayBrief(
                title: "Resolve past-due work",
                subtitle: "\(metrics.overdueTodos) past-due \(plural("work item", metrics.overdueTodos)) \(isVerb(metrics.overdueTodos)) still open. Handle, move, or dismiss \(objectPronoun(metrics.overdueTodos)).",
                actionTitle: "Review past-due work",
                systemImage: "clock.badge.exclamationmark",
                destination: .todos(.overdue)
            )
        }

        if metrics.atRiskContacts > 0 {
            return TodayBrief(
                title: "Relationship follow-ups",
                subtitle: "\(metrics.atRiskContacts) \(plural("person", metrics.atRiskContacts, plural: "people")) \(needsVerb(metrics.atRiskContacts)) a follow-up or status update.",
                actionTitle: "Review people",
                systemImage: "person.crop.circle.badge.exclamationmark",
                destination: .people(.atRisk)
            )
        }

        if metrics.dueTodayTodos > 0 {
            return TodayBrief(
                title: "Handle today's commitments",
                subtitle: "\(metrics.dueTodayTodos) \(plural("work item", metrics.dueTodayTodos)) \(isVerb(metrics.dueTodayTodos)) due today.",
                actionTitle: "Review today's work",
                systemImage: "calendar.badge.clock",
                destination: .todos(.today)
            )
        }

        if metrics.openTodos > 0 {
            return TodayBrief(
                title: "Triage open work",
                subtitle: "\(metrics.openTodos) open \(plural("work item", metrics.openTodos)) \(needsVerb(metrics.openTodos)) a date, next action, or close decision.",
                actionTitle: "Review open work",
                systemImage: "tray.full",
                destination: .todos(.open)
            )
        }

        return TodayBrief(
            title: "Plan the next move",
            subtitle: "No dated, high-priority, or relationship follow-up work is waiting in Today. Ask Maraithon for a summary, draft, or prioritization pass.",
            actionTitle: "Ask Maraithon",
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
        let todoItems = todos.compactMap { todo -> TodayFocusItem? in
            guard !todo.isCompleted else { return nil }

            if let dueDate = todo.dueDate,
               dueDate < now,
               !calendar.isDate(dueDate, inSameDayAs: now) {
                return TodayFocusItem(
                    kind: .todo,
                    referenceID: todo.id,
                    title: todo.title,
                    subtitle: todoFocusSubtitle(
                        for: todo,
                        fallback: dueSubtitle(for: dueDate, now: now),
                        prefix: dueSubtitle(for: dueDate, now: now)
                    ),
                    systemImage: "clock.badge.exclamationmark",
                    priority: 100 + priorityWeight(for: todo.priority)
                )
            }

            if let dueDate = todo.dueDate,
               calendar.isDate(dueDate, inSameDayAs: now) {
                return TodayFocusItem(
                    kind: .todo,
                    referenceID: todo.id,
                    title: todo.title,
                    subtitle: todoFocusSubtitle(for: todo, fallback: "Due today", prefix: "Today"),
                    systemImage: todo.priority.symbolName,
                    priority: 80 + priorityWeight(for: todo.priority)
                )
            }

            if todo.priority == .critical || todo.priority == .high {
                return TodayFocusItem(
                    kind: .todo,
                    referenceID: todo.id,
                    title: todo.title,
                    subtitle: todoFocusSubtitle(
                        for: todo,
                        fallback: "\(todo.priority.title) urgency",
                        prefix: todo.priority.title
                    ),
                    systemImage: todo.priority.symbolName,
                    priority: todo.priority == .critical ? 85 : 65
                )
            }

            return nil
        }

        let contactItems = contacts.compactMap { contact -> TodayFocusItem? in
            guard !CRMFiltering.isArchived(contact) else { return nil }

            if isAtRisk(contact, now: now, calendar: calendar) {
                return TodayFocusItem(
                    kind: .contact,
                    referenceID: contact.id,
                    title: contact.name,
                    subtitle: "\(relationshipContext(for: contact)) needs follow-up",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    priority: 75
                )
            }

            if contact.dealStage == .proposal,
               isStale(contact, now: now, calendar: calendar) {
                return TodayFocusItem(
                    kind: .contact,
                    referenceID: contact.id,
                    title: contact.name,
                    subtitle: "Follow up with \(relationshipContext(for: contact))",
                    systemImage: "person.wave.2",
                    priority: 60
                )
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
            .map(\.self)
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

    private static func todoFocusSubtitle(
        for todo: TodoItem,
        fallback: String,
        prefix: String
    ) -> String {
        guard let nextAction = todo.displayNextAction else {
            return fallback
        }

        return "\(prefix): \(nextAction)"
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
}
