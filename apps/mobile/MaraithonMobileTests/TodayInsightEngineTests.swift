import Foundation
import Testing
@testable import MaraithonMobile

@Suite("Today Insight Engine")
struct TodayInsightEngineTests {
    @Test
    func metricsTrackTodoWorkOnly() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let overdue = TodoItem(title: "Overdue", dueDate: now.addingTimeInterval(-2 * 24 * 60 * 60))
        let today = TodoItem(title: "Today", dueDate: now.addingTimeInterval(60))
        let completed = TodoItem(title: "Completed", dueDate: now, isCompleted: true)

        let metrics = TodayInsightEngine.metrics(
            todos: [overdue, today, completed],
            now: now,
            calendar: calendar
        )

        #expect(metrics.openTodos == 2)
        #expect(metrics.decisionTodos == 0)
        #expect(metrics.dueTodayTodos == 1)
        #expect(metrics.overdueTodos == 1)
    }

    @Test
    func metricsStayFastForLargeDecisionReadyAccounts() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let todos = (0..<500).map { index in
            TodoItem(
                title: "Decision \(index)",
                notes: "A customer is waiting on the update.",
                whyNow: "The customer is waiting and no later reply was found.",
                nextBestAction: "Send the update.",
                evidenceExcerpt: "Can you send the update?"
            )
        }

        var metrics: TodayMetrics?
        let elapsed = ContinuousClock().measure {
            metrics = TodayInsightEngine.metrics(
                todos: todos,
                now: now,
                calendar: calendar
            )
        }

        #expect(metrics?.decisionTodos == 500)
        #expect(elapsed < .seconds(1))
    }

    @Test
    func focusQueuePrioritizesOverdueTodosThenHighPriorityWork() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let overdue = TodoItem(
            title: "Send overdue proposal",
            priority: .high,
            dueDate: now.addingTimeInterval(-2 * 24 * 60 * 60)
        )
        let highPriority = TodoItem(title: "Book prep call", priority: .high)

        let queue = TodayInsightEngine.focusQueue(
            todos: [highPriority, overdue],
            now: now,
            calendar: calendar
        )

        #expect(queue.map(\.title) == ["Send overdue proposal", "Book prep call"])
        #expect(queue.first?.kind == .todo)
    }

    @Test
    func focusQueueGivesDefaultNextMoveForHighPriorityWork() {
        let critical = TodoItem(title: "Decide board response", priority: .critical)
        let high = TodoItem(title: "Book prep call", priority: .high)
        let normal = TodoItem(title: "Draft recap", priority: .medium)

        let queue = TodayInsightEngine.focusQueue(
            todos: [normal, high, critical]
        )

        #expect(queue.map(\.title) == ["Decide board response", "Book prep call", "Draft recap"])
        #expect(queue.map(\.subtitle) == [
            "Next: Decide, delegate, or schedule a concrete next move.",
            "Next: Decide, delegate, or schedule a concrete next move.",
            "Next: Choose the next move, schedule it, or dismiss it."
        ])
        #expect(queue[0].detail == "Critical priority.")
        #expect(queue[1].detail == "High priority.")
        #expect(queue[2].detail == "Open work.")
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
            now: now,
            calendar: calendar
        )

        #expect(queue.first?.subtitle == "Send the campaign update with a clear owner and timing.")
        #expect(queue.first?.detail?.localizedCaseInsensitiveContains("due ") == true)
        #expect(queue.first?.detail?.contains("Michael is waiting; no later reply is recorded.") == true)
        #expect(queue.first?.detail?.localizedCaseInsensitiveContains("why now:") == false)
        #expect(queue.first?.detail?.contains("Reviewed Gmail") == true)
    }

    @Test
    func focusQueueKeepsDueTodayDecisionCardsActionableAndEvidenceBacked() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let decision = TodoItem(
            title: "Approve Michael follow-up",
            nextAction: "Send the follow-up.",
            dueDate: now.addingTimeInterval(60),
            decisionPrompt: "Approve the Michael follow-up.",
            whyNow: "Michael is waiting on your answer.",
            sourceContext: "Checked Gmail",
            evidenceExcerpt: "Can you send the next campaign update today?"
        )
        let dueToday = TodoItem(
            title: "Review vendor renewal",
            nextAction: "Move or reschedule the vendor renewal.",
            dueDate: now.addingTimeInterval(120)
        )

        let queue = TodayInsightEngine.focusQueue(
            todos: [dueToday, decision],
            now: now,
            calendar: calendar
        )

        #expect(queue.map(\.title) == ["Approve Michael follow-up", "Review vendor renewal"])
        #expect(queue.first?.subtitle == "Approve the Michael follow-up.")
        #expect(queue.first?.detail == "Decision waiting. Due today. Michael is waiting on your answer. Can you send the next campaign update today? Reviewed Gmail")
        #expect(queue.first?.detail?.localizedCaseInsensitiveContains("evidence:") == false)
        #expect(queue.first?.systemImage == "checkmark.seal")
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
            now: now,
            calendar: calendar
        )

        #expect(queue.first?.subtitle == "You need to approve the finance reply.")
        #expect(queue.first?.detail == "Decision waiting. This needs your attention before noon. Reviewed Gmail")
        #expect(queue.first?.detail?.localizedCaseInsensitiveContains("telegram_fit_score") == false)
        #expect(queue.first?.detail?.localizedCaseInsensitiveContains("why now:") == false)
    }

    @Test
    func briefPrioritizesOverdueWorkThenDecisionsThenTodayThenOpenWorkThenChat() {
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

        #expect(TodayInsightEngine.brief(
            todos: [overdue, today],
            now: now,
            calendar: calendar
        ).destination == .todos(.overdue))

        #expect(TodayInsightEngine.brief(
            todos: [today, decision],
            now: now,
            calendar: calendar
        ).destination == .todos(.decisions))

        #expect(TodayInsightEngine.brief(
            todos: [today],
            now: now,
            calendar: calendar
        ).destination == .todos(.today))

        #expect(TodayInsightEngine.brief(
            todos: [open],
            now: now,
            calendar: calendar
        ).destination == .todos(.open))

        #expect(TodayInsightEngine.brief(
            todos: [],
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

        let brief = TodayInsightEngine.brief(todos: [decision])

        #expect(brief.title == "Make the calls waiting on you")
        #expect(brief.subtitle == "Decision needed: Approve investor reply. Send the revised terms and confirm the review window.")
        #expect(brief.actionTitle == "Review decisions")
        #expect(brief.destination == .todos(.decisions))
    }

    @Test
    func decisionBriefPrefersPreparedMoveFromActionCard() {
        let decision = TodoItem(
            title: "Reply to Michael",
            nextAction: "Reply to Michael.",
            decisionPrompt: "Choose the reply to Michael.",
            whyNow: "Michael is waiting on your answer.",
            nextBestAction: "Approve the short reply with campaign timing."
        )

        let brief = TodayInsightEngine.brief(todos: [decision])

        #expect(brief.subtitle == "Decision needed: Reply to Michael. Approve the short reply with campaign timing.")
    }

    @Test
    func clearDayBriefUsesMaraithonProductLanguage() {
        let brief = TodayInsightEngine.brief(todos: [])

        #expect(brief.title == "Nothing needs your review right now")
        #expect(brief.subtitle == "No saved decision, deadline, or open work item is waiting. Ask Maraithon for a fresh priority call, draft, or summary when you need one.")
        #expect(brief.actionTitle == "Start a review")
        #expect(!brief.actionTitle.localizedCaseInsensitiveContains("chief of staff"))
        #expect(!brief.subtitle.localizedCaseInsensitiveContains("high-priority"))
        #expect(!brief.subtitle.localizedCaseInsensitiveContains("Today. Ask"))
        #expect(!brief.subtitle.localizedCaseInsensitiveContains("needs action today"))
    }

    @Test
    func openUndatedWorkGetsATriageBriefBeforeChat() {
        let open = TodoItem(title: "Send partner recap")
        let completed = TodoItem(title: "Completed", isCompleted: true)

        let brief = TodayInsightEngine.brief(todos: [completed, open])

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
            now: now,
            calendar: calendar
        )

        #expect(brief.subtitle == "2 past-due work items need a decision. Start with Investor reply: Send the revised terms before the board packet closes.")
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
            now: now,
            calendar: calendar
        )

        #expect(brief.subtitle == "Customer support plan is due today. Reply with the owner and next review date.")
    }

    @Test
    func briefUsesGrammaticalSingularCountCopy() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let lateBrief = TodayInsightEngine.brief(
            todos: [TodoItem(title: "Overdue", dueDate: now.addingTimeInterval(-2 * 24 * 60 * 60))],
            now: now,
            calendar: calendar
        )
        #expect(lateBrief.title == "Resolve past-due work")
        #expect(lateBrief.subtitle == "Overdue is past due. Handle, move, or dismiss it.")
        #expect(lateBrief.actionTitle == "Review past-due work")

        let todayBrief = TodayInsightEngine.brief(
            todos: [TodoItem(title: "Board packet", dueDate: now.addingTimeInterval(60))],
            now: now,
            calendar: calendar
        )
        #expect(todayBrief.subtitle == "Board packet is due today. Move it before tomorrow or reschedule it.")
        #expect(todayBrief.title == "Handle today's commitments")
        #expect(todayBrief.actionTitle == "Review today's work")
    }
}
