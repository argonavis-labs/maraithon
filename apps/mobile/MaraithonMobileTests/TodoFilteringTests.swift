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
        let decision = TodoItem(
            title: "Approve investor reply",
            decisionPrompt: "Approve the investor reply with the revised terms.",
            whyNow: "The investor is waiting on your decision."
        )
        let today = TodoItem(title: "Today", dueDate: now.addingTimeInterval(60))
        let upcoming = TodoItem(title: "Upcoming", dueDate: now.addingTimeInterval(3 * 24 * 60 * 60))
        let completed = TodoItem(title: "Completed", dueDate: now, isCompleted: true)

        let todos = [overdue, decision, today, upcoming, completed]
        #expect(TodoFiltering.filter(todos, by: .open, now: now, calendar: calendar).map(\.title) == ["Overdue", "Approve investor reply", "Today", "Upcoming"])
        #expect(TodoFiltering.filter(todos, by: .decisions, now: now, calendar: calendar).map(\.title) == ["Approve investor reply"])
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
    func filtersByNextActionText() {
        let matching = TodoItem(
            title: "Investor reply",
            notes: "Short context.",
            nextAction: "Send the revised financing terms before the board packet closes."
        )
        let other = TodoItem(title: "Clean inbox", notes: "", priority: .low)

        let result = TodoFiltering.filter([matching, other], by: .all, searchText: "financing")

        #expect(result.map(\.title) == ["Investor reply"])
    }

    @Test
    func filtersByUserFacingUrgencyText() {
        let critical = TodoItem(title: "Prepare board answer", priority: .critical)
        let normal = TodoItem(title: "Draft recap", priority: .medium)

        #expect(TodoPriority.medium.title == "Normal")
        #expect(TodoFiltering.filter([critical, normal], by: .all, searchText: "critical").map(\.title) == ["Prepare board answer"])
        #expect(TodoFiltering.filter([critical, normal], by: .all, searchText: "normal").map(\.title) == ["Draft recap"])
        #expect(TodoFiltering.filter([critical, normal], by: .all, searchText: "medium").isEmpty)
    }

    @Test
    func countsMatchFilterResultsAndSearchText() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let overdue = TodoItem(title: "Runner renewal", dueDate: now.addingTimeInterval(-2 * 24 * 60 * 60))
        let decision = TodoItem(
            title: "Runner investor reply",
            decisionPrompt: "Approve the Runner investor reply.",
            whyNow: "Runner investor is waiting on your decision."
        )
        let today = TodoItem(title: "Runner prep", dueDate: now.addingTimeInterval(60))
        let upcoming = TodoItem(title: "Runner outreach", dueDate: now.addingTimeInterval(3 * 24 * 60 * 60))
        let completed = TodoItem(title: "Runner recap", dueDate: now, isCompleted: true)
        let other = TodoItem(title: "Clean inbox", dueDate: now.addingTimeInterval(60))

        let counts = TodoFiltering.counts(
            in: [overdue, decision, today, upcoming, completed, other],
            searchText: "runner",
            now: now,
            calendar: calendar
        )

        #expect(counts == TodoFilterCounts(all: 5, open: 4, decisions: 1, today: 1, overdue: 1, upcoming: 1, completed: 1))
        #expect(counts.value(for: .overdue) == TodoFiltering.filter(
            [overdue, decision, today, upcoming, completed, other],
            by: .overdue,
            searchText: "runner",
            now: now,
            calendar: calendar
        ).count)
    }

    @Test
    func emptyStateCopyMatchesSelectedFilter() {
        #expect(TodoFilter.open.navigationTitle == "Open Work")
        #expect(TodoFilter.decisions.title == "Decisions")
        #expect(TodoFilter.decisions.navigationTitle == "Decisions")
        #expect(TodoFilter.overdue.title == "Past due")
        #expect(TodoFilter.overdue.navigationTitle == "Past-due work")
        #expect(TodoFilter.completed.navigationTitle == "Completed")

        #expect(TodoFilter.open.emptyState(searchText: "", hasAnyWork: false) == TodoEmptyState(
            title: "No work yet",
            systemImage: "checklist",
            description: "Add a follow-up or ask Maraithon to turn messages, notes, and meetings into next actions."
        ))

        #expect(TodoFilter.overdue.emptyState(searchText: "", hasAnyWork: true) == TodoEmptyState(
            title: "No past-due work",
            systemImage: "clock.badge.checkmark",
            description: "No saved work is past due in this filter. Keep using Today for work that still needs a move."
        ))

        #expect(TodoFilter.all.emptyState(searchText: "", hasAnyWork: true).title == "No work in this view")
        #expect(TodoFilter.all.emptyState(searchText: "", hasAnyWork: true).description == "Reset filters or add the next follow-up Maraithon should keep visible.")
        #expect(TodoFilter.open.emptyState(searchText: "", hasAnyWork: true).description == "No open work is visible in this filter. Add the next commitment when it should stay on your radar.")
        #expect(TodoFilter.decisions.emptyState(searchText: "", hasAnyWork: true) == TodoEmptyState(
            title: "No decisions waiting",
            systemImage: "checkmark.seal",
            description: "Decision work appears here when Maraithon has enough context to ask for a call, approval, or keep-or-close choice."
        ))
        #expect(TodoFilter.today.emptyState(searchText: "", hasAnyWork: true).title == "No work due today")
        #expect(TodoFilter.upcoming.emptyState(searchText: "", hasAnyWork: true).title == "No upcoming work")
        #expect(TodoFilter.completed.emptyState(searchText: "", hasAnyWork: true).title == "No completed work")
    }

    @Test
    func emptyStateSearchCopyDoesNotMislabelTheActiveFilter() {
        let state = TodoFilter.completed.emptyState(searchText: " board ", hasAnyWork: true)

        #expect(state.title == "No matching work")
        #expect(state.systemImage == "magnifyingglass")
        #expect(state.description == "No completed work matches \"board\". Clear search or switch filters.")
    }

    @Test
    func emptyStateCopyAvoidsFalseAllClearLanguage() {
        let copy = TodoFilter.allCases
            .map { $0.emptyState(searchText: "", hasAnyWork: true).description }
            .joined(separator: " ")
            .lowercased()

        #expect(!copy.contains("nothing"))
        #expect(!copy.contains("needs action right now"))
        #expect(!copy.contains("you are clear"))
        #expect(!copy.contains("all saved work is completed"))
        #expect(!copy.contains("captured"))
    }

    @Test
    func workListSaveFailureCopyIsVisibleAndSpecific() {
        #expect(TodosViewCopy.actionWarningTitle == "Work item update was not saved")
        #expect(TodosViewCopy.dismissActionWarningAccessibilityLabel == "Dismiss work item warning")
        #expect(TodosViewCopy.localUpdateFailedMessage == "Could not update the work item on this device. Your work list stayed unchanged.")
        #expect(TodosViewCopy.localDeleteFailedMessage == "Could not delete the work item on this device. Your work list stayed unchanged.")
        #expect(TodosViewCopy.remoteUpdateSaveFailedMessage == "Maraithon updated the work item, but this device could not save the latest copy. Refresh work to reconcile.")
        #expect(TodosViewCopy.remoteDeleteSaveFailedMessage == "Maraithon deleted the work item, but this device could not remove the local copy. Refresh work to reconcile.")
        #expect(TodosViewCopy.restoreFailedMessage == "Could not restore the work item on this device. Refresh work to reconcile.")
        #expect(TodosViewCopy.localSaveFailureLabels.count == 7)
    }
}
