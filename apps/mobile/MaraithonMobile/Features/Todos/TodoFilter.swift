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
        case .overdue: "Late"
        case .upcoming: "Upcoming"
        case .completed: "Done"
        }
    }
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
            todo.priority.title,
            todo.contact?.name ?? "",
            todo.contact?.company ?? ""
        ]

        return searchableValues.contains { value in
            value.lowercased().contains(query)
        }
    }
}
