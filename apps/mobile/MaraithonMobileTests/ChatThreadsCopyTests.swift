import Testing
@testable import MaraithonMobile

@Suite("Chat Threads Copy")
struct ChatThreadsCopyTests {
    @Test
    @MainActor
    func sharedRefreshBannerUsesPlainCurrentDataLanguage() {
        let banner = SyncIssueBanner(message: "Could not refresh.", dismiss: {})

        #expect(banner.title == "Latest data may be out of date")
        #expect(banner.dismissAccessibilityLabel == "Dismiss warning")
        #expect(!banner.title.localizedCaseInsensitiveContains("stale"))
    }

    @Test
    func refreshFailureUsesActionableWarningCopy() {
        #expect(ChatThreadsCopy.refreshWarningTitle == "Chat list may be out of date")
        #expect(ChatThreadsCopy.refreshButtonTitle == "Refresh")
        #expect(!ChatThreadsCopy.refreshWarningTitle.localizedCaseInsensitiveContains("stale"))
    }

    @Test
    func localChatMutationsSurfaceSaveFailures() {
        #expect(ChatThreadsCopy.actionWarningTitle == "Chat update was not saved")
        #expect(ChatThreadsCopy.createFailedMessage == "Could not start a new chat. Your chat list stayed unchanged.")
        #expect(ChatThreadsCopy.deleteFailedMessage(count: 1) == "Could not delete that chat. Your chat list stayed unchanged.")
        #expect(ChatThreadsCopy.deleteFailedMessage(count: 2) == "Could not delete those chats. Your chat list stayed unchanged.")
        #expect(ChatThreadsCopy.dismissActionWarningAccessibilityLabel == "Dismiss chat update warning")
        #expect(ChatThreadsCopy.localSaveFailureLabels.count == 5)
    }

    @Test
    func emptyStatesUseSpecificSentenceCaseCopy() {
        #expect(ChatThreadsCopy.emptyChatsTitle == "No chats yet")
        #expect(ChatThreadsCopy.noMatchingChatsTitle == "No chats match")
        #expect(ChatThreadsCopy.deletedChatTitle == "Chat unavailable")
        #expect(ChatThreadsCopy.newChatButtonTitle == "New chat")
    }

    @Test
    func emptyStatesAvoidPlaceholderCopy() {
        let copy = ChatThreadsCopy.emptyStateLabels.joined(separator: " ")

        #expect(!copy.contains("No Chats"))
        #expect(!copy.contains("No Matching Chats"))
        #expect(!copy.contains("Chat Deleted"))
        #expect(!copy.contains("New Chat"))
    }
}
