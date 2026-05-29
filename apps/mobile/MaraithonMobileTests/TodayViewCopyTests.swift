import Testing
@testable import MaraithonMobile

@Suite("Today View Copy")
struct TodayViewCopyTests {
    @Test
    func prioritySnapshotUsesConcreteOperationalLabels() {
        #expect(TodayViewCopy.snapshotSectionTitle == "Priority Snapshot")
        #expect(TodayViewCopy.focusSectionTitle == "Focus queue")
        #expect(TodayViewCopy.recentChatsSectionTitle == "Recent chats")
        #expect(TodayViewCopy.openWorkTitle == "Open work")
        #expect(TodayViewCopy.overdueTitle == "Past due")
        #expect(TodayViewCopy.overdueSubtitle == "Needs action")
        #expect(TodayViewCopy.followUpTitle == "Needs follow-up")
        #expect(TodayViewCopy.followUpSubtitle == "Relationships need attention")
    }

    @Test
    func emptyStatesReadLikeExecutiveBriefs() {
        #expect(TodayViewCopy.emptyFocusTitle == "Nothing urgent")
        #expect(TodayViewCopy.emptyFocusDescription == "No past-due work or relationship follow-ups need attention.")
        #expect(TodayViewCopy.emptyRecentChatsTitle == "No recent chats")
        #expect(TodayViewCopy.emptyRecentChatsDescription == "Start a chat when you need a draft, summary, or prioritization pass.")
    }

    @Test
    func prioritySnapshotAvoidsGenericOrMisleadingLanguage() {
        let exactCopy = TodayViewCopy.snapshotLabels.joined(separator: " ")
        let copy = exactCopy.lowercased()

        #expect(!copy.contains("command center"))
        #expect(!copy.contains("needs a decision"))
        #expect(!copy.contains("outstanding work"))
        #expect(!copy.contains("stale active relationships"))
        #expect(!exactCopy.contains("No Recent Chats"))
        #expect(!exactCopy.contains("Nothing Urgent"))
    }
}
