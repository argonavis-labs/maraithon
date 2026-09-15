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

    var body: some View {
        NavigationStack {
            Form {
                Picker("Send", selection: $actor) {
                    Text("As me").tag("as_user")
                    Text("As my assistant").tag("as_assistant")
                }.disabled(busy)
                if let scope {
                    Section {
                        LabeledContent("From", value: scope.identity.email ?? scope.identity.displayName ?? "Assistant")
                        LabeledContent("Task owner", value: scope.taskOwner.title)
                        TextField("Outcome", text: $outcome, axis: .vertical)
                        if scope.provider == "gmail" {
                            TextField("With", text: $recipients)
                            TextField("Cc", text: $cc)
                        } else {
                            LabeledContent("Conversation", value: "Original Slack thread")
                        }
                        TextField("Instruction (optional)", text: $instruction, axis: .vertical)
                    }.disabled(busy)
                }
                if busy { ProgressView("Checking conversation") }
                if let error {
                    Text(error).foregroundStyle(.red)
                    if scope == nil { Button("Retry") { Task { await preview() } } }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Delegate this task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Delegate") { Task { await delegate() } }
                        .disabled(busy || scope == nil || outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || outcome.count > 2_000 || instruction.count > 2_000)
                }
            }
        }
        .task(id: actor) { await preview() }
        .interactiveDismissDisabled(busy)
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 440)
        #endif
    }

    @MainActor private func preview() async {
        busy = true; scope = nil; error = nil; pending = nil
        defer { busy = false }
        var input = TodoDelegation.Request()
        input.actor = actor
        do {
            guard let value = try await request("todos/\(todoID)/delegation/preview", input).scope else {
                throw URLError(.badServerResponse)
            }
            scope = value; outcome = value.outcome
            recipients = value.to.joined(separator: ", "); cc = value.cc.joined(separator: ", ")
        } catch { self.error = error.localizedDescription }
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
