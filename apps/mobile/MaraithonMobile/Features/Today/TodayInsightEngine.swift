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
            atRiskContacts: contacts.filter { isAtRisk($0, now: now, calendar: calendar) }.count
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
                title: "Triage late work first",
                subtitle: "\(metrics.overdueTodos) overdue \(plural("item", metrics.overdueTodos)) need a decision before new work gets added.",
                actionTitle: "Review Late",
                systemImage: "clock.badge.exclamationmark",
                destination: .todos(.overdue)
            )
        }

        if metrics.atRiskContacts > 0 {
            return TodayBrief(
                title: "Protect relationships today",
                subtitle: "\(metrics.atRiskContacts) \(plural("person", metrics.atRiskContacts, plural: "people")) need follow-up or a status update.",
                actionTitle: "Review People",
                systemImage: "person.crop.circle.badge.exclamationmark",
                destination: .people(.atRisk)
            )
        }

        if metrics.dueTodayTodos > 0 {
            return TodayBrief(
                title: "Clear today's commitments",
                subtitle: "\(metrics.dueTodayTodos) \(plural("todo", metrics.dueTodayTodos)) are due today.",
                actionTitle: "Review Today",
                systemImage: "calendar.badge.clock",
                destination: .todos(.today)
            )
        }

        return TodayBrief(
            title: "Plan the next move",
            subtitle: "No urgent work is blocking the day. Ask for a summary, draft, or prioritization pass.",
            actionTitle: "Ask Chief of Staff",
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
                    subtitle: dueSubtitle(for: dueDate, now: now),
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
                    subtitle: "Due today",
                    systemImage: todo.priority.symbolName,
                    priority: 80 + priorityWeight(for: todo.priority)
                )
            }

            if todo.priority == .high {
                return TodayFocusItem(
                    kind: .todo,
                    referenceID: todo.id,
                    title: todo.title,
                    subtitle: "High priority",
                    systemImage: todo.priority.symbolName,
                    priority: 65
                )
            }

            return nil
        }

        let contactItems = contacts.compactMap { contact -> TodayFocusItem? in
            guard contact.status != .closed, contact.dealStage != .lost else { return nil }

            if isAtRisk(contact, now: now, calendar: calendar) {
                return TodayFocusItem(
                    kind: .contact,
                    referenceID: contact.id,
                    title: contact.name,
                    subtitle: "\(contact.company) needs follow-up",
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
                    subtitle: "Follow up with \(contact.company)",
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
        contact.status == .atRisk || (contact.status == .active && isStale(contact, now: now, calendar: calendar))
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
        case .high: 15
        case .medium: 8
        case .low: 0
        }
    }

    private static func dueSubtitle(for dueDate: Date, now: Date) -> String {
        "Due \(AppFormatters.relativeString(for: dueDate, relativeTo: now))"
    }

    private static func plural(_ singular: String, _ count: Int, plural: String? = nil) -> String {
        count == 1 ? singular : (plural ?? "\(singular)s")
    }
}
