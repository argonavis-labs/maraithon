import Foundation

enum TodoFilter: String, CaseIterable, Hashable, Identifiable {
    case all
    case open
    case today
    case overdue
    case upcoming
    case completed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .open: "Open"
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
        case .today: "Today"
        case .overdue: "Past-due work"
        case .upcoming: "Upcoming"
        case .completed: "Completed"
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
                description: "Reset filters or add the next follow-up Maraithon should keep visible."
            )
        case .open:
            return TodoEmptyState(
                title: "No open work",
                systemImage: "checklist",
                description: "No open work is visible in this filter. Add the next commitment when it should stay on your radar."
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
    let today: Int
    let overdue: Int
    let upcoming: Int
    let completed: Int

    func value(for filter: TodoFilter) -> Int {
        switch filter {
        case .all: all
        case .open: open
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
