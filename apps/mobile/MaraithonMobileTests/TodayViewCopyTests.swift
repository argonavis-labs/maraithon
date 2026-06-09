import Testing
@testable import MaraithonMobile

@Suite("Today View Copy")
struct TodayViewCopyTests {
    @Test
    func nextActionsUsesConcreteOperationalLabels() {
        #expect(TodayViewCopy.actionSectionTitle == "Next actions")
        #expect(TodayViewCopy.focusSectionTitle == "Today's focus")
        #expect(TodayViewCopy.recentChatsSectionTitle == "Recent chats")
        #expect(TodayViewCopy.completeFocusActionLabel == "Done")
        #expect(TodayViewCopy.dismissFocusActionLabel == "Dismiss")
        #expect(TodayViewCopy.editFocusActionLabel == "Edit")
        #expect(TodayViewCopy.askMaraithonTitle == "Ask Maraithon")
        #expect(TodayViewCopy.askMaraithonSubtitle == "Plan, draft, or prioritize")
        #expect(TodayViewCopy.decisionsTitle == "Decisions")
        #expect(TodayViewCopy.decisionsSubtitle == "Calls waiting on you")
        #expect(TodayViewCopy.openWorkTitle == "Open work")
        #expect(TodayViewCopy.overdueTitle == "Past due")
        #expect(TodayViewCopy.overdueSubtitle == "Needs action")
    }

    @Test
    func emptyStatesReadLikeExecutiveBriefs() {
        #expect(TodayViewCopy.emptyFocusTitle == "Nothing needs your review right now")
        #expect(TodayViewCopy.emptyFocusDescription == "No saved decision, deadline, or open work item is waiting. Maraithon will surface the next concrete move when one appears.")
        #expect(TodayViewCopy.emptyRecentChatsTitle == "No recent chats")
        #expect(TodayViewCopy.emptyRecentChatsDescription == "Start a chat when you need a draft, summary, or prioritization pass.")

        let focusCopy = TodayViewCopy.emptyFocusDescription.lowercased()
        #expect(!focusCopy.contains("today shows"))
        #expect(!focusCopy.contains("use open work"))
        #expect(!focusCopy.contains("needs action today"))
        #expect(!focusCopy.contains("this view"))
    }

    @Test
    func saveFailureCopyUsesRecoveryLanguage() {
        #expect(TodayViewCopy.remoteCompleteSaveFailedMessage == "Maraithon completed the focus item. Refresh Today to show the latest state on this device.")
        #expect(TodayViewCopy.remoteDismissSaveFailedMessage == "Maraithon dismissed the focus item. Refresh Today to remove it from this device.")
        #expect(TodayViewCopy.restoreFocusFailedMessage == "Could not restore the focus item after the update failed. Refresh Today to show the latest state.")

        let copy = TodayViewCopy.actionLabels.joined(separator: " ").lowercased()
        #expect(!copy.contains("local copy"))
        #expect(!copy.contains("latest copy"))
        #expect(!copy.contains("reconcile"))
    }

    @Test
    func nextActionsAvoidsGenericOrMisleadingLanguage() {
        let exactCopy = TodayViewCopy.actionLabels.joined(separator: " ")
        let copy = exactCopy.lowercased()

        #expect(!copy.contains("priority snapshot"))
        #expect(!copy.contains("dashboard"))
        #expect(!copy.contains("command center"))
        #expect(!copy.contains("needs a decision"))
        #expect(!copy.contains("outstanding work"))
        #expect(!copy.contains("relationship follow-up"))
        #expect(!copy.contains("relationships need attention"))
        #expect(!copy.contains("stale active relationships"))
        #expect(!copy.contains("relationships tracked"))
        #expect(!copy.contains("queue"))
        #expect(!copy.contains("delete"))
        #expect(!exactCopy.contains("No Recent Chats"))
    }
}
