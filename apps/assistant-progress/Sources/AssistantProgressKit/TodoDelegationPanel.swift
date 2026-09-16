import SwiftUI

/// Shared Mac and iPhone controls for one durable, server-owned conversation.
public struct TodoDelegationPanel: View {
    public typealias Transport = (String, TodoDelegation.Request?) async throws -> TodoDelegation.Response
    private let todoID: String
    private let summary: TodoDelegation?
    private let canDelegate: Bool
    private let proposal: TodoDelegation.Proposal?
    private let request: Transport
    private let refreshTodo: () async -> Void
    @State private var current: TodoDelegation?
    @State private var showsGrant = false
    @State private var showsHistory = false
    @State private var busy = false
    @State private var error: String?
    @State private var answer = ""
    @State private var requestID = UUID().uuidString

    public init(todoID: String, summary: TodoDelegation?, canDelegate: Bool,
                proposal: TodoDelegation.Proposal? = nil,
                request: @escaping Transport, refreshTodo: @escaping () async -> Void) {
        self.todoID = todoID; self.summary = summary; self.canDelegate = canDelegate
        self.proposal = proposal
        self.request = request; self.refreshTodo = refreshTodo
        _current = State(initialValue: summary)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let current {
                Text(current.statusLine).font(.headline)
                Text(current.actorLabel).font(.caption).foregroundStyle(.secondary)
                if let action = current.lastAction { Text(action).font(.callout) }
                if let followUp = current.nextFollowUp,
                   let date = ISO8601DateFormatter().date(from: followUp), !current.isTerminal {
                    Text("Next follow-up: \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if current.holdReason == "send_may_be_in_flight" {
                    Text("One message may already be sending. Maraithon is checking its delivery.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let question = current.question { Text(question).font(.callout) }
                if current.controls.contains("answer") {
                    TextField("Your answer", text: $answer, axis: .vertical)
                    Button("Answer") { Task { await control("answer") } }
                        .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || answer.count > 2_000)
                }
                HStack {
                    ForEach(current.controls.filter { $0 != "answer" }, id: \.self) { action in
                        Button(Self.label(action)) { Task { await control(action) } }
                    }
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }
                }.buttonStyle(.borderless)
                Button("Conversation history", systemImage: "clock") { showsHistory = true }
                    .buttonStyle(.borderless)
            }
            if canDelegate && (current == nil || current?.isTerminal == true) {
                Button(proposal?.label ?? "Delegate", systemImage: "person.crop.circle.badge.checkmark") { showsGrant = true }
                if let proposal { Text(proposal.reason).font(.callout).foregroundStyle(.secondary) }
            }
            if busy { ProgressView().controlSize(.small).accessibilityLabel("Updating conversation") }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
        }
        .disabled(busy)
        .onChange(of: summary) { _, value in current = value }
        .onChange(of: answer) { _, _ in requestID = UUID().uuidString }
        .sheet(isPresented: $showsGrant) {
            TodoDelegationSheet(todoID: todoID, proposal: proposal, request: request) { value in
                current = value
                await refreshTodo()
            }
        }
        .sheet(isPresented: $showsHistory) {
            if let current { TodoDelegationHistoryView(delegationID: current.id, request: request) }
        }
    }

    @MainActor private func control(_ action: String) async {
        guard let current, current.controls.contains(action), !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        var input = TodoDelegation.Request()
        input.expectedRevision = current.revision
        input.requestID = "\(requestID):\(action):\(current.revision)"
        if action == "answer" { input.answer = answer }
        do {
            self.current = try await request("delegations/\(current.id)/\(action)", input).delegation
            requestID = UUID().uuidString
            answer = ""
            await refreshTodo()
        } catch {
            self.error = error.localizedDescription
            // A conflict or lost response reloads current authority; it never repeats a send.
            self.current = (try? await request("delegations/\(current.id)", nil))?.delegation ?? current
        }
    }

    @MainActor private func reload() async {
        guard let current, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            self.current = try await request("delegations/\(current.id)", nil).delegation
            await refreshTodo()
        } catch { self.error = error.localizedDescription }
    }

    private static func label(_ action: String) -> String {
        switch action {
        case "pause": "Pause"
        case "resume": "Resume"
        case "take_over": "Take over"
        case "stop": "Stop"
        default: action.capitalized
        }
    }
}
