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

    @Test
    func normalizesSignInCode() {
        #expect(SignInCodeParser.normalizedCode(from: " abcd-2345 ") == "ABCD2345")
        #expect(SignInCodeParser.normalizedCode(from: "ABCD 2345") == "ABCD2345")
    }

    @Test
    func formatsSignInCode() {
        #expect(SignInCodeParser.formattedCode(from: "abcd2345") == "ABCD-2345")
    }

    @Test
    func rejectsMalformedSignInCode() {
        #expect(SignInCodeParser.normalizedCode(from: "abc") == nil)
        #expect(SignInCodeParser.normalizedCode(from: "abcd-23456") == nil)
    }
}
