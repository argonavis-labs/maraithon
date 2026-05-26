import Foundation
import Testing
@testable import MaraithonMobile

@Suite("Today Insight Engine")
struct TodayInsightEngineTests {
    @Test
    func metricsCombineTodosAndPeople() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let overdue = TodoItem(title: "Overdue", dueDate: now.addingTimeInterval(-2 * 24 * 60 * 60))
        let today = TodoItem(title: "Today", dueDate: now.addingTimeInterval(60))
        let completed = TodoItem(title: "Completed", dueDate: now, isCompleted: true)
        let staleActive = CRMContact(
            name: "Ada Chen",
            company: "Northstar",
            email: "ada@example.com",
            status: .active,
            dealStage: .proposal,
            lastContactedAt: now.addingTimeInterval(-10 * 24 * 60 * 60)
        )
        let lost = CRMContact(
            name: "Archived Person",
            company: "Acme",
            email: "lost@example.com",
            dealStage: .lost
        )

        let metrics = TodayInsightEngine.metrics(
            todos: [overdue, today, completed],
            contacts: [staleActive, lost],
            now: now,
            calendar: calendar
        )

        #expect(metrics.openTodos == 2)
        #expect(metrics.dueTodayTodos == 1)
        #expect(metrics.overdueTodos == 1)
        #expect(metrics.peopleCount == 2)
        #expect(metrics.atRiskContacts == 1)
    }

    @Test
    func focusQueuePrioritizesOverdueTodosThenStaleRelationships() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let overdue = TodoItem(
            title: "Send overdue proposal",
            priority: .high,
            dueDate: now.addingTimeInterval(-2 * 24 * 60 * 60)
        )
        let highPriority = TodoItem(title: "Book prep call", priority: .high)
        let staleActive = CRMContact(
            name: "Ada Chen",
            company: "Northstar",
            email: "ada@example.com",
            status: .active,
            dealStage: .qualified,
            lastContactedAt: now.addingTimeInterval(-10 * 24 * 60 * 60)
        )

        let queue = TodayInsightEngine.focusQueue(
            todos: [highPriority, overdue],
            contacts: [staleActive],
            now: now,
            calendar: calendar
        )

        #expect(queue.map(\.title) == ["Send overdue proposal", "Ada Chen", "Book prep call"])
        #expect(queue.first?.kind == .todo)
    }

    @Test
    func briefPrioritizesOverdueWorkThenRelationshipsThenTodayThenChat() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let overdue = TodoItem(title: "Overdue", dueDate: now.addingTimeInterval(-2 * 24 * 60 * 60))
        let today = TodoItem(title: "Today", dueDate: now.addingTimeInterval(60))
        let staleActive = CRMContact(
            name: "Ada Chen",
            company: "Northstar",
            email: "ada@example.com",
            status: .active,
            lastContactedAt: now.addingTimeInterval(-10 * 24 * 60 * 60)
        )

        #expect(TodayInsightEngine.brief(
            todos: [overdue, today],
            contacts: [staleActive],
            now: now,
            calendar: calendar
        ).destination == .todos(.overdue))

        #expect(TodayInsightEngine.brief(
            todos: [today],
            contacts: [staleActive],
            now: now,
            calendar: calendar
        ).destination == .people(.atRisk))

        #expect(TodayInsightEngine.brief(
            todos: [today],
            contacts: [],
            now: now,
            calendar: calendar
        ).destination == .todos(.today))

        #expect(TodayInsightEngine.brief(
            todos: [],
            contacts: [],
            now: now,
            calendar: calendar
        ).destination == .chat)
    }
}
