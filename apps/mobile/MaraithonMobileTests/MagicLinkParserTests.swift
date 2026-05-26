import Testing
@testable import MaraithonMobile

@Suite("Magic Link Parser")
struct MagicLinkParserTests {
    @Test
    func parsesRawToken() {
        #expect(MagicLinkParser.token(from: " token-123 ") == "token-123")
    }

    @Test
    func parsesWebMagicLink() {
        let token = MagicLinkParser.token(from: "https://maraithon.app/auth/magic/token-123")

        #expect(token == "token-123")
    }

    @Test
    func parsesAppMagicLink() {
        let token = MagicLinkParser.token(from: "maraithon://auth/magic/token-123")

        #expect(token == "token-123")
    }

    @Test
    func rejectsUnrelatedURL() {
        #expect(MagicLinkParser.token(from: "https://maraithon.app/settings/token-123") == nil)
    }
}
