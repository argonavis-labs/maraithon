import Testing
@testable import MaraithonMobile

@Suite("Account Menu Copy")
struct AccountMenuCopyTests {
    @Test
    func resetCopyUsesUserFacingWorkspaceLanguage() {
        #expect(AccountMenuCopy.activityLogLabel == "Activity Log")
        #expect(AccountMenuCopy.resetLocalWorkspaceLabel == "Reset Local Workspace")
        #expect(AccountMenuCopy.resetLocalWorkspaceTitle == "Reset local workspace?")
        #expect(AccountMenuCopy.resetFailedTitle == "Could Not Reset Workspace")
        #expect(AccountMenuCopy.resetFailedFallback == "Reset did not complete. Close and reopen Maraithon before resetting local workspace.")

        for visibleString in AccountMenuCopy.resetVisibleStrings {
            #expect(!visibleString.localizedCaseInsensitiveContains("starter"))
            #expect(!visibleString.localizedCaseInsensitiveContains("demo"))
            #expect(!visibleString.localizedCaseInsensitiveContains("debug"))
            #expect(!visibleString.localizedCaseInsensitiveContains("try again"))
            #expect(!visibleString.localizedCaseInsensitiveContains("retrying"))
        }
    }
}
