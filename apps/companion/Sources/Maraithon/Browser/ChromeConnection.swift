/// Bounded DevTools transport. A timeout closes the connection; commands are never replayed.
import Foundation

actor ChromeConnection {
    private let socket: URLSessionWebSocketTask
    private var sequence = 0
    private var pending: [Int: CheckedContinuation<BrowserJSON, Error>] = [:]
    private var receiver: Task<Void, Never>?
    private var closed = false

    init(url: URL) {
        socket = URLSession.shared.webSocketTask(with: url)
        socket.maximumMessageSize = 2 * 1_024 * 1_024
        socket.resume()
    }

    func call(_ method: String, _ params: [String: BrowserJSON] = [:], session: String? = nil) async throws -> BrowserJSON {
        guard !closed else { throw BrowserFailure("Chrome disconnected. Inspect the page again before continuing.") }
        if receiver == nil { receiver = Task { await self.receive() } }
        sequence += 1
        let id = sequence
        var message: [String: BrowserJSON] = ["id": .number(Double(id)), "method": .string(method), "params": .object(params)]
        if let session { message["sessionId"] = .string(session) }
        let data = try JSONEncoder().encode(BrowserJSON.object(message))
        guard let text = String(data: data, encoding: .utf8) else { throw BrowserFailure("Could not encode browser command.") }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do { try await socket.send(.string(text)) }
                catch { close() }
            }
            Task {
                try? await Task.sleep(for: .seconds(8))
                if pending[id] != nil { close() }
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        socket.cancel(with: .goingAway, reason: nil)
        receiver?.cancel()
        receiver = nil
        let waiting = pending.values
        pending.removeAll()
        for continuation in waiting {
            continuation.resume(throwing: BrowserFailure("Chrome did not confirm the step. Inspect the page before trying again.", uncertain: true))
        }
    }

    private func receive() async {
        do {
            while !Task.isCancelled {
                let frame = try await socket.receive()
                let data: Data
                switch frame {
                case .data(let v): data = v
                case .string(let v): data = Data(v.utf8)
                @unknown default: continue
                }
                let message = try JSONDecoder().decode(BrowserJSON.self, from: data)
                guard let id = message["id"].integer, let continuation = pending.removeValue(forKey: id) else { continue }
                if message["error"]["message"].string != nil {
                    continuation.resume(throwing: BrowserFailure("Chrome could not perform this step. Take a fresh page snapshot."))
                } else { continuation.resume(returning: message["result"]) }
            }
        } catch { close() }
    }
}

struct BrowserFailure: LocalizedError, Sendable {
    let message: String
    let uncertain: Bool
    init(_ message: String, uncertain: Bool = false) { self.message = message; self.uncertain = uncertain }
    var errorDescription: String? { message }
}
