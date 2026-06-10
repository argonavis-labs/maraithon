import XCTest
@testable import Maraithon

@MainActor
final class DeviceAuthTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "device-auth-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testBeginPairingTransitionsToAwaitingApproval() {
        let log = EventLog(capacity: 64)
        let keychain = InMemoryKeychain()
        var openedURL: URL?
        let auth = DeviceAuth(
            eventLog: log,
            keychain: keychain,
            defaults: defaults,
            deviceName: "Test-Mac",
            clientFactory: { _ in MaraithonClient(tokenProvider: { nil }, transport: { _ in throw URLError(.unknown) }) },
            urlOpener: { url in openedURL = url }
        )

        auth.beginPairing()

        if case .awaitingApproval(let id) = auth.state {
            XCTAssertEqual(id, auth.deviceId)
        } else {
            XCTFail("Expected awaitingApproval, got \(auth.state)")
        }
        let opened = try? XCTUnwrap(openedURL)
        XCTAssertEqual(opened?.host, "maraithon.fly.dev")
        XCTAssertEqual(opened?.path, "/companion/auth")
        let q = URLComponents(url: opened!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(q.contains(URLQueryItem(name: "device_id", value: auth.deviceId.uuidString)))
        XCTAssertTrue(q.contains(URLQueryItem(name: "device_name", value: "Test-Mac")))
    }

    func testDeviceIdPersistsAcrossInstances() {
        let log = EventLog(capacity: 16)
        let a = DeviceAuth(
            eventLog: log,
            keychain: InMemoryKeychain(),
            defaults: defaults,
            clientFactory: { _ in MaraithonClient(tokenProvider: { nil }, transport: { _ in throw URLError(.unknown) }) },
            urlOpener: { _ in }
        )
        let firstId = a.deviceId
        let b = DeviceAuth(
            eventLog: log,
            keychain: InMemoryKeychain(),
            defaults: defaults,
            clientFactory: { _ in MaraithonClient(tokenProvider: { nil }, transport: { _ in throw URLError(.unknown) }) },
            urlOpener: { _ in }
        )
        XCTAssertEqual(b.deviceId, firstId)
    }

    func testHandleIncomingURLStoresTokenAndSignsIn() async {
        let log = EventLog(capacity: 64)
        let keychain = InMemoryKeychain()
        let account = DeviceAuth.Account(email: "kent@example.com", deviceName: "Test")
        let body = try! JSONEncoder().encode(account)
        let client = MaraithonClient(
            tokenProvider: { "tok" },
            transport: { _ in
                let http = HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (body, http)
            }
        )
        let auth = DeviceAuth(
            eventLog: log,
            keychain: keychain,
            defaults: defaults,
            clientFactory: { _ in client },
            urlOpener: { _ in }
        )

        let url = URL(string: "maraithon://device-token/abc")!
        auth.handleIncomingURL(url)

        // The Task spun inside handleIncomingURL runs on the main actor;
        // yield until the state settles.
        for _ in 0..<50 {
            if case .signedIn = auth.state { break }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(try? keychain.get(), "abc")
        if case .signedIn(let a) = auth.state {
            XCTAssertEqual(a.email, "kent@example.com")
        } else {
            XCTFail("Expected signedIn, got \(auth.state)")
        }
    }

    func testHandleIncomingURLKeepsTokenAndUsesRecoveryCopyWhenVerificationFails() async throws {
        let log = EventLog(capacity: 64)
        let keychain = InMemoryKeychain()
        let auth = DeviceAuth(
            eventLog: log,
            keychain: keychain,
            defaults: defaults,
            clientFactory: { _ in MaraithonClient(tokenProvider: { "tok" }, transport: { _ in throw URLError(.timedOut) }) },
            urlOpener: { _ in }
        )

        auth.handleIncomingURL(URL(string: "maraithon://device-token/tok")!)

        for _ in 0..<50 {
            if case .error = auth.state { break }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(try keychain.get(), "tok")
        if case .error(let message) = auth.state {
            XCTAssertEqual(message, "Could not verify account. Reopen Maraithon to finish pairing.")
            XCTAssertFalse(message.localizedCaseInsensitiveContains("try again"))
        } else {
            XCTFail("Expected error state, got \(auth.state)")
        }
    }

    func testHandleIncomingURLIgnoresWrongScheme() {
        let log = EventLog(capacity: 16)
        let keychain = InMemoryKeychain()
        let auth = DeviceAuth(
            eventLog: log,
            keychain: keychain,
            defaults: defaults,
            clientFactory: { _ in MaraithonClient(tokenProvider: { nil }, transport: { _ in throw URLError(.unknown) }) },
            urlOpener: { _ in }
        )
        XCTAssertEqual(auth.state, .signedOut)
        auth.handleIncomingURL(URL(string: "https://example.com/foo")!)
        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertNil(try? keychain.get())
    }

    func testSignOutClearsKeychain() throws {
        let log = EventLog(capacity: 16)
        let keychain = InMemoryKeychain(initial: "tok")
        let auth = DeviceAuth(
            eventLog: log,
            keychain: keychain,
            defaults: defaults,
            clientFactory: { _ in MaraithonClient(tokenProvider: { nil }, transport: { _ in throw URLError(.unknown) }) },
            urlOpener: { _ in }
        )
        XCTAssertEqual(auth.currentToken, "tok")
        auth.signOut()
        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertNil(try keychain.get())
        XCTAssertNil(auth.currentToken)
    }

    func testTokenRejectedClearsTokenAndSurfacesError() throws {
        let log = EventLog(capacity: 16)
        let keychain = InMemoryKeychain(initial: "tok")
        let auth = DeviceAuth(
            eventLog: log,
            keychain: keychain,
            defaults: defaults,
            clientFactory: { _ in MaraithonClient(tokenProvider: { nil }, transport: { _ in throw URLError(.unknown) }) },
            urlOpener: { _ in }
        )
        auth.tokenRejected()
        if case .error = auth.state {
            // ok
        } else {
            XCTFail("Expected error state")
        }
        XCTAssertNil(try keychain.get())
    }
}
