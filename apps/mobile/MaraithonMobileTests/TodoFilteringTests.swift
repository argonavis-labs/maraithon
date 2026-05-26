import Foundation
import Testing
@testable import MaraithonMobile

@Suite("Todo Filtering")
struct TodoFilteringTests {
    @Test
    func filtersTodayUpcomingAndCompleted() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let overdue = TodoItem(title: "Overdue", dueDate: now.addingTimeInterval(-2 * 24 * 60 * 60))
        let today = TodoItem(title: "Today", dueDate: now.addingTimeInterval(60))
        let upcoming = TodoItem(title: "Upcoming", dueDate: now.addingTimeInterval(3 * 24 * 60 * 60))
        let completed = TodoItem(title: "Completed", dueDate: now, isCompleted: true)

        let todos = [overdue, today, upcoming, completed]
        #expect(TodoFiltering.filter(todos, by: .open, now: now, calendar: calendar).map(\.title) == ["Overdue", "Today", "Upcoming"])
        #expect(TodoFiltering.filter(todos, by: .today, now: now, calendar: calendar).map(\.title) == ["Today"])
        #expect(TodoFiltering.filter(todos, by: .overdue, now: now, calendar: calendar).map(\.title) == ["Overdue"])
        #expect(TodoFiltering.filter(todos, by: .upcoming, now: now, calendar: calendar).map(\.title) == ["Upcoming"])
        #expect(TodoFiltering.filter(todos, by: .completed, now: now, calendar: calendar).map(\.title) == ["Completed"])
    }

    @Test
    func filtersBySearchText() {
        let matching = TodoItem(title: "Send proposal", notes: "Northstar update", priority: .high)
        let other = TodoItem(title: "Clean inbox", notes: "", priority: .low)

        let result = TodoFiltering.filter([matching, other], by: .all, searchText: "proposal")

        #expect(result.map(\.title) == ["Send proposal"])
    }

    @Test
    func countsMatchFilterResultsAndSearchText() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let overdue = TodoItem(title: "Runner renewal", dueDate: now.addingTimeInterval(-2 * 24 * 60 * 60))
        let today = TodoItem(title: "Runner prep", dueDate: now.addingTimeInterval(60))
        let upcoming = TodoItem(title: "Runner outreach", dueDate: now.addingTimeInterval(3 * 24 * 60 * 60))
        let completed = TodoItem(title: "Runner recap", dueDate: now, isCompleted: true)
        let other = TodoItem(title: "Clean inbox", dueDate: now.addingTimeInterval(60))

        let counts = TodoFiltering.counts(
            in: [overdue, today, upcoming, completed, other],
            searchText: "runner",
            now: now,
            calendar: calendar
        )

        #expect(counts == TodoFilterCounts(all: 4, open: 3, today: 1, overdue: 1, upcoming: 1, completed: 1))
        #expect(counts.value(for: .overdue) == TodoFiltering.filter(
            [overdue, today, upcoming, completed, other],
            by: .overdue,
            searchText: "runner",
            now: now,
            calendar: calendar
        ).count)
    }
}
