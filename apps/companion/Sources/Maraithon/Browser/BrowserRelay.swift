/// Outbound paired-device relay. A claimed command executes once; only its result may be retried.
import Foundation
import CryptoKit

actor BrowserRelay {
    struct Command: Decodable, Sendable {
        let id: String
        let todo_id: String
        let operation: String
        let payload: [String: String]
        let expires_at: String
        var deadline: Date {
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return parser.date(from: expires_at) ?? .distantPast
        }
    }
    struct Claim: Decodable, Sendable { let command: Command?; let user_id: String }
    private let client: MaraithonClient
    private var loop: Task<Void, Never>?
    private var browser: TodoChromeBrowser?
    private var account: String?
    private let log: @Sendable (String) -> Void

    init(client: MaraithonClient, log: @escaping @Sendable (String) -> Void) {
        self.client = client
        self.log = log
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { await self.run() }
    }

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            do {
                let claim: Claim = try await client.browserRequest(path: "/claim", body: ["available": .bool(TodoChromeBrowser.isInstalled)])
                failures = 0
                if account != claim.user_id {
                    await browser?.disconnect()
                    account = claim.user_id
                    let scope = SHA256.hash(data: Data(claim.user_id.utf8)).map { String(format: "%02x", $0) }.joined()
                    browser = TodoChromeBrowser(accountScope: scope)
                }
                if let command = claim.command, let browser {
                    guard command.deadline.timeIntervalSinceNow > 2 else { continue }
                    log("browser.step_started")
                    let result: [String: String]
                    do { result = try await browser.execute(command) }
                    catch {
                        let failure = error as? BrowserFailure
                        result = ["error": failure?.message ?? "Chrome could not complete the step. Inspect the page before trying again.",
                            "error_class": failure?.uncertain == false ? "failed" : "ambiguous"]
                    }
                    // An HTTP failure only resends this result. It never repeats the interaction.
                    await report(command: command, result: result)
                    log(result["error"] == nil ? "browser.step_completed" : "browser.step_failed")
                } else { try await Task.sleep(for: .seconds(5)) }
            } catch {
                failures = min(failures + 1, 5)
                if failures == 1 { log("browser.relay_disconnected") }
                try? await Task.sleep(for: .seconds(min(30, 1 << failures)))
            }
        }
    }

    private func report(command: Command, result: [String: String]) async {
        struct Reply: Decodable { let accepted: Bool }
        while command.deadline > Date() && !Task.isCancelled {
            do {
                let _: Reply = try await client.browserRequest(path: "/\(command.id)/result", body: ["result": .strings(result)])
                return
            } catch { try? await Task.sleep(for: .seconds(2)) }
        }
        log("browser.result_unconfirmed")
    }
}
