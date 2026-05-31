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
        #expect(metrics.decisionTodos == 0)
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

        #expect(queue.first { $0.referenceID == atRisk.id }?.subtitle == "Next: Follow up with Ada Chen")
        #expect(queue.first { $0.referenceID == proposal.id }?.subtitle == "Next: Follow up with Mason Patel")
    }

    @Test
    func focusQueueGivesDefaultNextMoveForHighPriorityWork() {
        let critical = TodoItem(title: "Decide board response", priority: .critical)
        let high = TodoItem(title: "Book prep call", priority: .high)
        let normal = TodoItem(title: "Draft recap", priority: .medium)

        let queue = TodayInsightEngine.focusQueue(
            todos: [normal, high, critical],
            contacts: []
        )

        #expect(queue.map(\.title) == ["Decide board response", "Book prep call"])
        #expect(queue.map(\.subtitle) == [
            "Next: Decide, delegate, or schedule a concrete next move.",
            "Next: Decide, delegate, or schedule a concrete next move."
        ])
        #expect(queue[0].detail == "Critical priority.")
        #expect(queue[1].detail == "High priority.")
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
        #expect(queue[0].subtitle == "Next: Send the revised terms before the board packet closes.")
        #expect(queue[0].detail?.hasPrefix("Due ") == true)
        #expect(queue[1].subtitle == "Next: Reply with the support plan, owner, and next review date.")
        #expect(queue[1].detail == "Due today.")
        #expect(queue[2].subtitle == "Next: Choose the answer and send it to the board thread.")
        #expect(queue[2].detail == "Critical priority.")
    }

    @Test
    func focusQueueUsesSyncedDecisionCardContextWhenAvailable() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let todo = TodoItem(
            title: "Reply to Michael",
            notes: "Michael is waiting on the campaign update.",
            nextAction: "Approve the short reply.",
            priority: .high,
            dueDate: now.addingTimeInterval(-2 * 24 * 60 * 60),
            decisionPrompt: "Decide whether to send the campaign owner and ETA.",
            whyNow: "Michael is waiting and no later reply was found.",
            sourceContext: "Checked Gmail"
        )

        let queue = TodayInsightEngine.focusQueue(
            todos: [todo],
            contacts: [],
            now: now,
            calendar: calendar
        )

        #expect(queue.first?.subtitle == "Send the campaign update with a clear owner and timing.")
        #expect(queue.first?.detail?.localizedCaseInsensitiveContains("due ") == true)
        #expect(queue.first?.detail?.contains("Why now: Michael is waiting; no later reply is recorded.") == true)
        #expect(queue.first?.detail?.contains("Reviewed Gmail") == true)
    }

    @Test
    func focusQueuePolishesSyncedChiefOfStaffCopy() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let todo = TodoItem(
            title: "Finance reply",
            nextAction: "User should send the ETA.",
            priority: .high,
            decisionPrompt: "The user needs to approve the finance reply.",
            whyNow: "This needs operator attention before noon.",
            sourceContext: "source_context: Checked Gmail\ntelegram_fit_score: 0.94"
        )

        let queue = TodayInsightEngine.focusQueue(
            todos: [todo],
            contacts: [],
            now: now,
            calendar: calendar
        )

        #expect(queue.first?.subtitle == "You need to approve the finance reply.")
        #expect(queue.first?.detail == "Decision waiting. Why now: This needs your attention before noon. Reviewed Gmail")
        #expect(queue.first?.detail?.localizedCaseInsensitiveContains("telegram_fit_score") == false)
    }

    @Test
    func focusQueueExplainsRelationshipCareRecency() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let lastContactedAt = now.addingTimeInterval(-10 * 24 * 60 * 60)
        let staleActive = CRMContact(
            name: "Ada Chen",
            company: "Northstar",
            email: "ada@example.com",
            status: .active,
            lastContactedAt: lastContactedAt,
            notes: "Prefers concise weekly updates."
        )

        let queue = TodayInsightEngine.focusQueue(
            todos: [],
            contacts: [staleActive],
            now: now,
            calendar: calendar
        )

        #expect(queue.first?.title == "Ada Chen")
        #expect(queue.first?.subtitle == "Next: Follow up with Northstar")
        #expect(queue.first?.detail == "Last reached out \(AppFormatters.relativeString(for: lastContactedAt, relativeTo: now)). Prefers concise weekly updates.")
    }

    @Test
    func briefPrioritizesOverdueWorkThenDecisionsThenTodayThenRelationshipsThenOpenWorkThenChat() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let overdue = TodoItem(title: "Overdue", dueDate: now.addingTimeInterval(-2 * 24 * 60 * 60))
        let decision = TodoItem(
            title: "Approve investor reply",
            decisionPrompt: "Approve the investor reply with the revised terms.",
            whyNow: "The investor is waiting on your decision."
        )
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
            todos: [today, decision],
            contacts: [staleActive],
            now: now,
            calendar: calendar
        ).destination == .todos(.decisions))

        #expect(TodayInsightEngine.brief(
            todos: [today],
            contacts: [staleActive],
            now: now,
            calendar: calendar
        ).destination == .todos(.today))

        #expect(TodayInsightEngine.brief(
            todos: [],
            contacts: [staleActive],
            now: now,
            calendar: calendar
        ).destination == .people(.atRisk))

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
    func decisionBriefNamesTheCallWaitingOnTheExecutive() {
        let decision = TodoItem(
            title: "Approve investor reply",
            nextAction: "Send the revised terms and confirm the review window",
            decisionPrompt: "Approve the investor reply with the revised terms.",
            whyNow: "The investor is waiting on your decision."
        )

        let brief = TodayInsightEngine.brief(todos: [decision], contacts: [])

        #expect(brief.title == "Make the calls waiting on you")
        #expect(brief.subtitle == "Approve investor reply needs a decision. Send the revised terms and confirm the review window.")
        #expect(brief.actionTitle == "Review decisions")
        #expect(brief.destination == .todos(.decisions))
    }

    @Test
    func clearDayBriefUsesMaraithonProductLanguage() {
        let brief = TodayInsightEngine.brief(todos: [], contacts: [])

        #expect(brief.title == "Clear for now")
        #expect(brief.subtitle == "No decision, deadline, or relationship follow-up needs action today. Start a planning chat when you want a draft, summary, or priority call.")
        #expect(brief.actionTitle == "Start a chat")
        #expect(!brief.actionTitle.localizedCaseInsensitiveContains("chief of staff"))
        #expect(!brief.subtitle.localizedCaseInsensitiveContains("high-priority"))
        #expect(!brief.subtitle.localizedCaseInsensitiveContains("Today. Ask"))
    }

    @Test
    func openUndatedWorkGetsATriageBriefBeforeChat() {
        let open = TodoItem(title: "Send partner recap")
        let completed = TodoItem(title: "Completed", isCompleted: true)

        let brief = TodayInsightEngine.brief(todos: [completed, open], contacts: [])

        #expect(brief.title == "Triage open work")
        #expect(brief.subtitle == "Send partner recap needs a date, next action, or close decision.")
        #expect(brief.actionTitle == "Review open work")
        #expect(brief.destination == .todos(.open))
    }

    @Test
    func briefNamesTheHighestSignalWorkItem() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let investorReply = TodoItem(
            title: "Investor reply",
            nextAction: "Send the revised terms before the board packet closes",
            priority: .critical,
            dueDate: now.addingTimeInterval(-2 * 24 * 60 * 60)
        )
        let vendorRenewal = TodoItem(
            title: "Vendor renewal",
            priority: .medium,
            dueDate: now.addingTimeInterval(-5 * 24 * 60 * 60)
        )

        let brief = TodayInsightEngine.brief(
            todos: [vendorRenewal, investorReply],
            contacts: [],
            now: now,
            calendar: calendar
        )

        #expect(brief.subtitle == "2 past-due work items are still open. Start with Investor reply: Send the revised terms before the board packet closes.")
    }

    @Test
    func briefUsesConcreteNextMoveForSingleDueItem() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = TodoItem(
            title: "Customer support plan",
            nextAction: "Reply with the owner and next review date",
            dueDate: now.addingTimeInterval(60)
        )

        let brief = TodayInsightEngine.brief(
            todos: [today],
            contacts: [],
            now: now,
            calendar: calendar
        )

        #expect(brief.subtitle == "Customer support plan is due today. Reply with the owner and next review date.")
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
        #expect(brief.subtitle == "Ada Chen at Northstar needs a follow-up or status update.")
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
        #expect(lateBrief.subtitle == "Overdue is past due. Handle, move, or dismiss it.")
        #expect(lateBrief.actionTitle == "Review past-due work")

        let todayBrief = TodayInsightEngine.brief(
            todos: [TodoItem(title: "Board packet", dueDate: now.addingTimeInterval(60))],
            contacts: [],
            now: now,
            calendar: calendar
        )
        #expect(todayBrief.subtitle == "Board packet is due today. Move it before tomorrow or reschedule it.")
        #expect(todayBrief.title == "Handle today's commitments")
        #expect(todayBrief.actionTitle == "Review today's work")
    }
}
