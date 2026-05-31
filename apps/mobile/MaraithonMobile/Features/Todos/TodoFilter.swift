import Foundation

enum TodoFilter: String, CaseIterable, Hashable, Identifiable {
    case all
    case open
    case decisions
    case today
    case overdue
    case upcoming
    case completed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .open: "Open"
        case .decisions: "Decisions"
        case .today: "Today"
        case .overdue: "Past due"
        case .upcoming: "Upcoming"
        case .completed: "Done"
        }
    }

    var navigationTitle: String {
        switch self {
        case .all: "All Work"
        case .open: "Open Work"
        case .decisions: "Decisions"
        case .today: "Today"
        case .overdue: "Past-due work"
        case .upcoming: "Upcoming"
        case .completed: "Completed"
        }
    }

    var searchPrompt: String {
        switch self {
        case .all: "Search work"
        case .open: "Search open work"
        case .decisions: "Search decisions"
        case .today: "Search today's work"
        case .overdue: "Search past-due work"
        case .upcoming: "Search upcoming work"
        case .completed: "Search completed work"
        }
    }

    func emptyState(searchText: String, hasAnyWork: Bool) -> TodoEmptyState {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !query.isEmpty {
            return TodoEmptyState(
                title: "No matching work",
                systemImage: "magnifyingglass",
                description: "No \(searchScopeLabel) matches \"\(query)\". Clear search or switch filters."
            )
        }

        if !hasAnyWork {
            return TodoEmptyState(
                title: "No work yet",
                systemImage: "checklist",
                description: "Add a follow-up or ask Maraithon to turn messages, notes, and meetings into next actions."
            )
        }

        switch self {
        case .all:
            return TodoEmptyState(
                title: "No work in this view",
                systemImage: "checklist",
                description: "Reset filters, add a follow-up, or ask Maraithon to keep a commitment visible."
            )
        case .open:
            return TodoEmptyState(
                title: "No open work",
                systemImage: "checklist",
                description: "This filter has no open work. Add a follow-up, or ask Maraithon to keep the next commitment visible."
            )
        case .decisions:
            return TodoEmptyState(
                title: "No decisions waiting",
                systemImage: "checkmark.seal",
                description: "Decision work appears here when Maraithon has enough context to ask for a call, approval, or keep-or-close choice."
            )
        case .today:
            return TodoEmptyState(
                title: "No work due today",
                systemImage: "calendar",
                description: "No saved work in this filter is due today. Pull one open item into today when it needs movement before tomorrow."
            )
        case .overdue:
            return TodoEmptyState(
                title: "No past-due work",
                systemImage: "clock.badge.checkmark",
                description: "No saved work is past due in this filter. Keep using Today for work that still needs a move."
            )
        case .upcoming:
            return TodoEmptyState(
                title: "No upcoming work",
                systemImage: "calendar.badge.clock",
                description: "Future-dated commitments appear here once a due date is set."
            )
        case .completed:
            return TodoEmptyState(
                title: "No completed work",
                systemImage: "checkmark.circle",
                description: "Closed items appear here after you mark work done."
            )
        }
    }

    private var searchScopeLabel: String {
        switch self {
        case .all: "work"
        case .open: "open work"
        case .decisions: "decisions"
        case .today: "work due today"
        case .overdue: "past-due work"
        case .upcoming: "upcoming work"
        case .completed: "completed work"
        }
    }
}

struct TodoEmptyState: Equatable {
    let title: String
    let systemImage: String
    let description: String
}

struct TodoFilterCounts: Equatable {
    let all: Int
    let open: Int
    let decisions: Int
    let today: Int
    let overdue: Int
    let upcoming: Int
    let completed: Int

    func value(for filter: TodoFilter) -> Int {
        switch filter {
        case .all: all
        case .open: open
        case .decisions: decisions
        case .today: today
        case .overdue: overdue
        case .upcoming: upcoming
        case .completed: completed
        }
    }
}

enum TodoFiltering {
    static func counts(
        in todos: [TodoItem],
        searchText: String = "",
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TodoFilterCounts {
        TodoFilterCounts(
            all: filter(todos, by: .all, searchText: searchText, now: now, calendar: calendar).count,
            open: filter(todos, by: .open, searchText: searchText, now: now, calendar: calendar).count,
            decisions: filter(todos, by: .decisions, searchText: searchText, now: now, calendar: calendar).count,
            today: filter(todos, by: .today, searchText: searchText, now: now, calendar: calendar).count,
            overdue: filter(todos, by: .overdue, searchText: searchText, now: now, calendar: calendar).count,
            upcoming: filter(todos, by: .upcoming, searchText: searchText, now: now, calendar: calendar).count,
            completed: filter(todos, by: .completed, searchText: searchText, now: now, calendar: calendar).count
        )
    }

    static func filter(
        _ todos: [TodoItem],
        by filter: TodoFilter,
        searchText: String = "",
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [TodoItem] {
        todos.filter { todo in
            guard matchesSearch(todo, searchText: searchText) else { return false }

            switch filter {
            case .all:
                return true
            case .open:
                return !todo.isCompleted
            case .decisions:
                return TodoDecisionSignals.needsDecision(todo)
            case .today:
                guard let dueDate = todo.dueDate else { return false }
                return !todo.isCompleted && calendar.isDate(dueDate, inSameDayAs: now)
            case .overdue:
                guard let dueDate = todo.dueDate else { return false }
                return !todo.isCompleted && dueDate < now && !calendar.isDate(dueDate, inSameDayAs: now)
            case .upcoming:
                guard let dueDate = todo.dueDate else { return false }
                return !todo.isCompleted && dueDate > now && !calendar.isDate(dueDate, inSameDayAs: now)
            case .completed:
                return todo.isCompleted
            }
        }
    }

    static func overdueCount(
        in todos: [TodoItem],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        filter(todos, by: .overdue, now: now, calendar: calendar).count
    }

    private static func matchesSearch(_ todo: TodoItem, searchText: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }

        let searchableValues = [
            todo.title,
            todo.notes,
            todo.nextAction ?? "",
            todo.priority.title,
            todo.contact?.name ?? "",
            todo.contact?.company ?? ""
        ]

        return searchableValues.contains { value in
            value.lowercased().contains(query)
        }
    }
}

enum TodoDecisionSignals {
    static func needsDecision(_ todo: TodoItem) -> Bool {
        guard !todo.isCompleted else { return false }

        let context = TodoDecisionContext(todo: todo)

        if let decisionPrompt = context.decisionPrompt,
           !isGenericDecisionPrompt(decisionPrompt) {
            return true
        }

        if waitingSignal(in: context.whyNow) || waitingSignal(in: context.notesContext) {
            return true
        }

        if context.preparedMove != nil, context.evidence != nil {
            return true
        }

        return false
    }

    static func signalPillTitle(for todo: TodoItem) -> String? {
        needsDecision(todo) ? "Decision" : nil
    }

    private static func isGenericDecisionPrompt(_ value: String) -> Bool {
        let normalized = normalize(value)

        let genericPrompts = [
            "handle this now snooze it or dismiss it",
            "keep it active if it still matters or dismiss it so it stops resurfacing"
        ]

        return genericPrompts.contains(normalized)
    }

    private static func waitingSignal(in value: String?) -> Bool {
        guard let value else { return false }
        let lower = value.lowercased()

        return [
            "waiting",
            "needs your reply",
            "needs your decision",
            "no later reply",
            "you owe",
            "you need to approve",
            "before noon",
            "before today",
            "before tomorrow",
            "due today"
        ].contains { lower.contains($0) }
    }

    private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
