import Testing
@testable import MaraithonMobile

@Suite("Chat Detail Error Copy")
struct ChatDetailErrorCopyTests {
    @Test
    func chatDetailControlsUseSentenceCaseCopy() {
        #expect(ChatDetailCopy.deleteMessageTitle == "Delete message")
        #expect(ChatDetailCopy.threadOptionsAccessibilityLabel == "Thread options")
        #expect(ChatDetailCopy.renameAlertTitle == "Rename chat")
        #expect(ChatDetailCopy.messageOptionsAccessibilityLabel == "Message options")
        #expect(ChatDetailCopy.sendMessageAccessibilityLabel == "Send message")
        #expect(ChatDetailCopy.emptyTitle == "Ask Maraithon")
        #expect(!ChatDetailCopy.visibleLabels.contains("Delete Message"))
        #expect(!ChatDetailCopy.visibleLabels.contains("Thread Options"))
        #expect(!ChatDetailCopy.visibleLabels.contains("Rename Chat"))
        #expect(!ChatDetailCopy.visibleLabels.contains("Message Options"))
        #expect(!ChatDetailCopy.visibleLabels.contains("Send Message"))
    }

    @Test
    func sendFailuresOfferRetry() {
        #expect(ChatDetailErrorCopy.recoveryActionTitle(canRetrySend: true) == "Send again")
    }

    @Test
    func nonSendFailuresOfferRefresh() {
        #expect(ChatDetailErrorCopy.recoveryActionTitle(canRetrySend: false) == "Refresh chat")
    }

    @Test
    func chatSyncErrorsMatchVisibleRecoveryActions() {
        #expect(ChatSyncError.emptyMessage.localizedDescription == "Enter a message before sending.")
        #expect(
            ChatSyncError.pollingTimedOut.localizedDescription ==
                "Maraithon is still working. Refresh this chat in a moment."
        )
        #expect(!ChatSyncError.pollingTimedOut.localizedDescription.localizedCaseInsensitiveContains("pull"))
    }
}
