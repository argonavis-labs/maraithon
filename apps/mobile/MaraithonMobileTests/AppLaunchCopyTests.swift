import Testing
@testable import MaraithonMobile

@Suite("App Launch Copy")
struct AppLaunchCopyTests {
    @Test
    func launchProgressAvoidsSessionLanguage() {
        #expect(AppLaunchCopy.checkingAccount == "Opening Maraithon")
        #expect(!AppLaunchCopy.checkingAccount.localizedCaseInsensitiveContains("session"))
    }
}
