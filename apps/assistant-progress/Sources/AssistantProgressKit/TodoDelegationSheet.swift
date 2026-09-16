import SwiftUI

/// Grants the reviewed source-derived scope once; changing actor requires a new preview.
struct TodoDelegationSheet: View {
    let todoID: String
    let request: TodoDelegationPanel.Transport
    let finished: (TodoDelegation?) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var actor = "as_user"
    @State private var scope: TodoDelegation.Scope?
    @State private var outcome = ""
    @State private var instruction = ""
    @State private var recipients = ""
    @State private var cc = ""
    @State private var busy = false
    @State private var error: String?
    @State private var pending: TodoDelegation.Request?
    @State private var preflightID: String?
    @State private var previewVersion = UUID()
    @State private var previewAttempt = UUID()
    private let kind: String

    init(todoID: String, proposal: TodoDelegation.Proposal?, request: @escaping TodoDelegationPanel.Transport,
         finished: @escaping (TodoDelegation?) async -> Void) {
        self.todoID = todoID; self.request = request; self.finished = finished
        self.kind = proposal?.kind ?? "information"
        _actor = State(initialValue: proposal?.actor ?? "as_user")
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Send", selection: $actor) {
                    Text("As me").tag("as_user")
                    Text("As my assistant").tag("as_assistant")
                }.disabled(busy && scope != nil)
                if let scope {
                    Section {
                        LabeledContent("From", value: scope.identity.email ?? scope.identity.displayName ?? "Assistant")
                        LabeledContent("Task owner", value: scope.taskOwner.title)
                        TextField("Outcome", text: $outcome, axis: .vertical)
                        if scope.provider == "gmail" {
                            TextField("With", text: $recipients)
                            TextField("Cc", text: $cc)
                            if let copies = scope.firstSendCc, !copies.isEmpty {
                                LabeledContent("Copy on first message", value: copies.joined(separator: ", "))
                            }
                        } else {
                            LabeledContent("Conversation", value: "Original Slack thread")
                        }
                        TextField("Instruction (optional)", text: $instruction, axis: .vertical)
                    }.disabled(busy)
                }
                if busy {
                    ProgressView(scope == nil ? "Checking conversation" : "Starting delegation")
                    if scope == nil { Text("You can close this and return later.").foregroundStyle(.secondary) }
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                    if scope == nil { Button("Retry") { previewAttempt = UUID() }.disabled(busy) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Delegate this task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy && scope != nil) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Delegate") { Task { await delegate() } }
                        .disabled(busy || scope == nil || outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || outcome.count > 2_000 || instruction.count > 2_000)
                }
            }
        }
        .task(id: "\(actor):\(previewAttempt)") { await preview() }
        .interactiveDismissDisabled(busy && scope != nil)
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 440)
        #endif
    }

    @MainActor private func preview() async {
        let version = UUID()
        previewVersion = version
        busy = true; scope = nil; error = nil; pending = nil; preflightID = nil
        defer { if previewVersion == version { busy = false } }
        var input = TodoDelegation.Request()
        input.actor = actor
        input.kind = kind
        input.asyncPreview = true
        do {
            while !Task.isCancelled {
                let response = try await request("todos/\(todoID)/delegation/preview", input)
                try Task.checkCancellation()
                guard previewVersion == version else { return }
                if let value = response.scope {
                    preflightID = response.preflight?.id
                    scope = value; outcome = value.outcome
                    recipients = value.to.joined(separator: ", "); cc = value.cc.joined(separator: ", ")
                    return
                }
                guard let check = response.preflight, check.status == "pending" else {
                    throw URLError(.badServerResponse)
                }
                input.preflightID = check.id
                try await Task.sleep(for: .milliseconds(min(max(check.retryAfterMs ?? 2_000, 1_000), 30_000)))
            }
        } catch {
            guard !Task.isCancelled, previewVersion == version else { return }
            self.error = error.localizedDescription
        }
    }

    @MainActor private func delegate() async {
        guard let scope, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        var input = TodoDelegation.Request()
        input.actor = scope.actor; input.kind = scope.kind
        input.outcome = outcome; input.instruction = instruction
        input.to = addresses(recipients); input.cc = addresses(cc)
        input.scopeHash = scope.scopeHash; input.expectedRevision = scope.workflowRevision
        input.preflightID = preflightID
        if let pending { input.requestID = pending.requestID }
        if let pending, pending != input { input.requestID = UUID().uuidString }
        pending = input
        do {
            let response = try await request("todos/\(todoID)/delegation", input)
            await finished(response.delegation)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func addresses(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
