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
                title: "No work matches this filter",
                systemImage: "checklist",
                description: "Switch filters, add a follow-up, or ask Maraithon to keep a commitment visible."
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
                description: "No saved work in this filter is due today. Move one open item into today when the next decision belongs there."
            )
        case .overdue:
            return TodoEmptyState(
                title: "No past-due work",
                systemImage: "clock.badge.checkmark",
                description: "No saved work is past due in this filter. Today will keep decision-ready work visible."
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
    /// Single pass over the todos with per-filter accumulators; the previous
    /// implementation ran the full filter pipeline seven times.
    static func counts(
        in todos: [TodoItem],
        searchText: String = "",
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TodoFilterCounts {
        let query = normalizedQuery(searchText)
        var all = 0
        var open = 0
        var decisions = 0
        var today = 0
        var overdue = 0
        var upcoming = 0
        var completed = 0

        for todo in todos {
            guard matchesSearch(todo, query: query) else { continue }

            all += 1

            if todo.isCompleted {
                completed += 1
            } else {
                open += 1
            }

            if TodoDecisionSignals.needsDecision(todo) {
                decisions += 1
            }

            if !todo.isCompleted, let dueDate = todo.dueDate {
                if calendar.isDate(dueDate, inSameDayAs: now) {
                    today += 1
                } else if dueDate < now {
                    overdue += 1
                } else if dueDate > now {
                    upcoming += 1
                }
            }
        }

        return TodoFilterCounts(
            all: all,
            open: open,
            decisions: decisions,
            today: today,
            overdue: overdue,
            upcoming: upcoming,
            completed: completed
        )
    }

    static func filter(
        _ todos: [TodoItem],
        by filter: TodoFilter,
        searchText: String = "",
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [TodoItem] {
        let query = normalizedQuery(searchText)

        return todos.filter { todo in
            guard matchesSearch(todo, query: query) else { return false }

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
        }.sorted(by: mostRecentlyUpdatedFirst)
    }

    private static func mostRecentlyUpdatedFirst(_ lhs: TodoItem, _ rhs: TodoItem) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func overdueCount(
        in todos: [TodoItem],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        filter(todos, by: .overdue, now: now, calendar: calendar).count
    }

    private static func normalizedQuery(_ searchText: String) -> String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func matchesSearch(_ todo: TodoItem, query: String) -> Bool {
        guard !query.isEmpty else { return true }

        if todo.title.lowercased().contains(query) { return true }
        if todo.notes.lowercased().contains(query) { return true }
        if let nextAction = todo.nextAction, nextAction.lowercased().contains(query) { return true }
        if todo.priority.title.lowercased().contains(query) { return true }

        if let contact = todo.contact {
            if contact.name.lowercased().contains(query) { return true }
            if contact.company.lowercased().contains(query) { return true }
        }

        return false
    }
}

/// Content fingerprint over the todo fields that feed derived list state
/// (filters, counts, decision signals, focus queues). Views compare it in
/// `onChange` to decide when a cached snapshot must be rebuilt; identity-based
/// array equality would miss in-place edits like completing a todo.
enum TodoListSignature {
    static func signature(for todos: [TodoItem]) -> Int {
        var hasher = Hasher()
        hasher.combine(todos.count)

        for todo in todos {
            hasher.combine(todo.id)
            hasher.combine(todo.title)
            hasher.combine(todo.notes)
            hasher.combine(todo.nextAction)
            hasher.combine(todo.isCompleted)
            hasher.combine(todo.dueDate)
            hasher.combine(todo.priorityRawValue)
            hasher.combine(todo.updatedAt)
            hasher.combine(todo.decisionPrompt)
            hasher.combine(todo.decisionContextSummary)
            hasher.combine(todo.whyNow)
            hasher.combine(todo.sourceContext)
            hasher.combine(todo.nextBestAction)
            hasher.combine(todo.draftPreview)
            hasher.combine(todo.evidenceExcerpt)
            hasher.combine(todo.sourceSystem)
        }

        return hasher.finalize()
    }
}

enum TodoDecisionSignals {
    static func needsDecision(_ todo: TodoItem) -> Bool {
        guard !todo.isCompleted else { return false }

        if let decisionPrompt = ChiefOfStaffCopy.clean(todo.decisionPrompt),
           !isGenericDecisionPrompt(decisionPrompt) {
            return true
        }

        if waitingSignal(in: todo.whyNow) ||
            waitingSignal(in: todo.notes) ||
            waitingSignal(in: todo.decisionContextSummary) {
            return true
        }

        if hasSignalText(todo.nextBestAction), hasSignalText(todo.evidenceExcerpt) {
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
            "needs operator attention",
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

    private static func hasSignalText(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
