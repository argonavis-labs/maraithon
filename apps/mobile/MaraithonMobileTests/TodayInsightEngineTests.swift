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
    func focusQueueUsesPersonNameWhenRelationshipContextIsEmpty() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let atRisk = CRMContact(
            name: "Ada Chen",
            company: "   ",
            email: "ada@example.com",
            status: .atRisk
        )
        let proposal = CRMContact(
            name: "Mason Patel",
            company: "",
            email: "mason@example.com",
            dealStage: .proposal
        )

        let queue = TodayInsightEngine.focusQueue(
            todos: [],
            contacts: [proposal, atRisk],
            now: now,
            calendar: calendar
        )

        #expect(queue.first { $0.referenceID == atRisk.id }?.subtitle == "Ada Chen needs follow-up")
        #expect(queue.first { $0.referenceID == proposal.id }?.subtitle == "Follow up with Mason Patel")
    }

    @Test
    func focusQueueUsesUrgencyLanguageForHighUrgencyTodos() {
        let critical = TodoItem(title: "Decide board response", priority: .critical)
        let high = TodoItem(title: "Book prep call", priority: .high)
        let normal = TodoItem(title: "Draft recap", priority: .medium)

        let queue = TodayInsightEngine.focusQueue(
            todos: [normal, high, critical],
            contacts: []
        )

        #expect(queue.map(\.title) == ["Decide board response", "Book prep call"])
        #expect(queue.map(\.subtitle) == ["Critical urgency", "High urgency"])
    }

    @Test
    func focusQueueShowsConcreteNextActionsWhenAvailable() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let overdue = TodoItem(
            title: "Investor reply",
            notes: "The financing terms are waiting.",
            nextAction: "Send the revised terms before the board packet closes.",
            dueDate: now.addingTimeInterval(-2 * 24 * 60 * 60)
        )

        let today = TodoItem(
            title: "Customer support plan",
            notes: "The customer asked whether the plan is ready.",
            nextAction: "Reply with the support plan, owner, and next review date.",
            dueDate: now.addingTimeInterval(60)
        )

        let critical = TodoItem(
            title: "Decide board response",
            nextAction: "Choose the answer and send it to the board thread.",
            priority: .critical
        )

        let queue = TodayInsightEngine.focusQueue(
            todos: [critical, today, overdue],
            contacts: [],
            now: now,
            calendar: calendar
        )

        #expect(queue.map(\.title) == ["Investor reply", "Customer support plan", "Decide board response"])
        #expect(queue[0].subtitle.contains("Send the revised terms"))
        #expect(queue[1].subtitle == "Today: Reply with the support plan, owner, and next review date.")
        #expect(queue[2].subtitle == "Critical: Choose the answer and send it to the board thread.")
    }

    @Test
    func briefPrioritizesOverdueWorkThenRelationshipsThenTodayThenOpenWorkThenChat() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let overdue = TodoItem(title: "Overdue", dueDate: now.addingTimeInterval(-2 * 24 * 60 * 60))
        let today = TodoItem(title: "Today", dueDate: now.addingTimeInterval(60))
        let open = TodoItem(title: "Undated follow-up")
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
            todos: [open],
            contacts: [],
            now: now,
            calendar: calendar
        ).destination == .todos(.open))

        #expect(TodayInsightEngine.brief(
            todos: [],
            contacts: [],
            now: now,
            calendar: calendar
        ).destination == .chat)
    }

    @Test
    func clearDayBriefUsesMaraithonProductLanguage() {
        let brief = TodayInsightEngine.brief(todos: [], contacts: [])

        #expect(brief.title == "Plan the next move")
        #expect(brief.subtitle == "No dated, high-priority, or relationship follow-up work is waiting in Today. Ask Maraithon for a summary, draft, or prioritization pass.")
        #expect(brief.actionTitle == "Ask Maraithon")
        #expect(!brief.actionTitle.localizedCaseInsensitiveContains("chief of staff"))
    }

    @Test
    func openUndatedWorkGetsATriageBriefBeforeChat() {
        let open = TodoItem(title: "Send partner recap")
        let completed = TodoItem(title: "Completed", isCompleted: true)

        let brief = TodayInsightEngine.brief(todos: [completed, open], contacts: [])

        #expect(brief.title == "Triage open work")
        #expect(brief.subtitle == "1 open work item needs a date, next action, or close decision.")
        #expect(brief.actionTitle == "Review open work")
        #expect(brief.destination == .todos(.open))
    }

    @Test
    func relationshipBriefCountMatchesPeopleNeedsCareFilter() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let staleActive = CRMContact(
            name: "Ada Chen",
            company: "Northstar",
            email: "ada@example.com",
            status: .active,
            lastContactedAt: now.addingTimeInterval(-10 * 24 * 60 * 60)
        )
        let archivedAtRisk = CRMContact(
            name: "Archived Person",
            company: "Acme",
            email: "archived@example.com",
            status: .atRisk,
            dealStage: .lost,
            lastContactedAt: now.addingTimeInterval(-30 * 24 * 60 * 60)
        )

        let contacts = [staleActive, archivedAtRisk]
        let metrics = TodayInsightEngine.metrics(
            todos: [],
            contacts: contacts,
            now: now,
            calendar: calendar
        )
        let peopleFilter = CRMFiltering.filter(
            contacts,
            statusFilter: .atRisk,
            now: now,
            calendar: calendar
        )
        let brief = TodayInsightEngine.brief(
            todos: [],
            contacts: contacts,
            now: now,
            calendar: calendar
        )

        #expect(metrics.atRiskContacts == 1)
        #expect(peopleFilter.map(\.name) == ["Ada Chen"])
        #expect(metrics.atRiskContacts == peopleFilter.count)
        #expect(brief.destination == .people(.atRisk))
        #expect(brief.title == "Relationship follow-ups")
        #expect(brief.subtitle == "1 person needs a follow-up or status update.")
        #expect(brief.actionTitle == "Review people")
    }

    @Test
    func briefUsesGrammaticalSingularCountCopy() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let lateBrief = TodayInsightEngine.brief(
            todos: [TodoItem(title: "Overdue", dueDate: now.addingTimeInterval(-2 * 24 * 60 * 60))],
            contacts: [],
            now: now,
            calendar: calendar
        )
        #expect(lateBrief.title == "Resolve past-due work")
        #expect(lateBrief.subtitle == "1 past-due work item is still open. Handle, move, or dismiss it.")
        #expect(lateBrief.actionTitle == "Review past-due work")

        let todayBrief = TodayInsightEngine.brief(
            todos: [TodoItem(title: "Today", dueDate: now.addingTimeInterval(60))],
            contacts: [],
            now: now,
            calendar: calendar
        )
        #expect(todayBrief.subtitle == "1 work item is due today.")
        #expect(todayBrief.title == "Handle today's commitments")
        #expect(todayBrief.actionTitle == "Review today's work")
    }
}
