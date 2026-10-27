/// Observes durable todo preparation with a bounded wait and an explicit retry.
/// A missing brief alone never means that the server is still working.
import Foundation
import Observation

@Observable @MainActor
final class TodoBriefPreparationStore {
    enum State: Equatable {
        case idle, checking, queued, generating, deferred
        case failed(String)

        var message: String? {
            switch self {
            case .idle: return nil
            case .checking: return "Checking preparation…"
            case .queued: return "Preparation is queued. You can keep working."
            case .generating: return "Preparing people and next steps…"
            case .deferred: return "Preparation is taking longer than expected."
            case .failed(let message): return message
            }
        }

        var isWorking: Bool { self == .checking || self == .generating }
        var canRetry: Bool {
            switch self {
            case .failed, .deferred: return true
            default: return false
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var revision = 0
    private let client: MaraithonClient

    init(client: MaraithonClient) { self.client = client }

    func retry() {
        state = .checking
        revision += 1
    }

    static func needsPreparation(_ todo: CompanionTodo) -> Bool {
        todo.brief == nil && todo.delegation == nil && ["triage", "open", "snoozed"].contains(todo.status)
    }

    func observe(todo: CompanionTodo, update: (CompanionTodo) -> Void) async {
        guard Self.needsPreparation(todo) else { state = .idle; return }
        state = .checking
        let deadline = ContinuousClock.now.advanced(by: .seconds(360))
        do {
            // Opening or retrying schedules durable work. The server deduplicates
            // an existing job, so checking again cannot start a second model call.
            try await client.markTodoOpened(id: todo.id)
            try Task.checkCancellation()
            while ContinuousClock.now < deadline {
                let details = try await client.todoDetails(id: todo.id)
                try Task.checkCancellation()
                update(details.todo)
                guard Self.needsPreparation(details.todo) else { state = .idle; return }
                switch details.briefPreparation {
                case "generating": state = .generating
                case "queued": state = .queued
                case nil: state = .queued // Older servers remain bounded too.
                default:
                    state = .failed("Could not finish preparing this todo.")
                    return
                }
                try await Task.sleep(for: .seconds(5))
            }
            state = .deferred
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled else { return }
            state = .failed("Could not load preparation. " + CompanionErrorCopy.message(for: error))
        }
    }
}
