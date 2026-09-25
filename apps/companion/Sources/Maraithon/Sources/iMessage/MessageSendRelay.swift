/// Claims only user-approved Messages commands. Each claim runs once; network
/// retries resend the receipt, never the message. The server owns the queue.
import Foundation

actor MessageSendRelay {
    struct Command: Decodable, Sendable {
        let id: String
        let payload: [String: String?]
        let expires_at: String
        var deadline: Date { CompanionConversation.date(from: expires_at) ?? .distantPast }
    }
    struct Claim: Decodable, Sendable { let command: Command? }
    private let client: MaraithonClient
    private var loop: Task<Void, Never>?
    private let log: @Sendable (String) -> Void

    init(client: MaraithonClient, log: @escaping @Sendable (String) -> Void) {
        self.client = client
        self.log = log
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { await run() }
    }

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            do {
                let claim: Claim = try await client.messageSendRequest(path: "/claim", body: ["available": .bool(true)])
                failures = 0
                if let command = claim.command {
                    guard command.deadline.timeIntervalSinceNow > 5 else { continue }
                    log("imessage.send_started")
                    let result = await MessageSender.send(recipient: (command.payload["recipient"] ?? nil) ?? "",
                                                          body: (command.payload["body"] ?? nil) ?? "")
                    await report(command, result)
                    log(result["status"] == "sent" ? "imessage.send_confirmed" : "imessage.send_unconfirmed")
                } else { try await Task.sleep(for: .seconds(5)) }
            } catch {
                failures = min(failures + 1, 5)
                try? await Task.sleep(for: .seconds(min(30, 1 << failures)))
            }
        }
    }

    private func report(_ command: Command, _ result: [String: String]) async {
        struct Reply: Decodable { let accepted: Bool }
        for _ in 0..<5 {
            do {
                let _: Reply = try await client.messageSendRequest(path: "/\(command.id)/result", body: ["result": .strings(result)])
                return
            } catch { try? await Task.sleep(for: .seconds(2)) }
        }
        log("imessage.receipt_unconfirmed")
    }
}
