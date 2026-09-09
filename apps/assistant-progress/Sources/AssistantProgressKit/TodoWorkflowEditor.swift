import SwiftUI

/// Shared native state and owner controls. The API validates ownership and version.
public struct TodoWorkflowEditor: View {
    private let workflow: TodoWorkflow
    private let people: [TodoWorkflow.Owner]
    private let save: (TodoWorkflowChange) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var state: String
    @State private var ownerID: String
    @State private var outcome: String
    @State private var nextAction: String
    @State private var reason = ""
    @State private var reviewDate: Date
    @State private var hasReviewDate: Bool
    @State private var saving = false
    @State private var error: String?
    @State private var pendingChange: TodoWorkflowChange?

    public init(workflow: TodoWorkflow, people: [TodoWorkflow.Owner],
                save: @escaping (TodoWorkflowChange) async throws -> Void) {
        self.workflow = workflow; self.people = people; self.save = save
        _state = State(initialValue: workflow.state)
        _ownerID = State(initialValue: workflow.owner.selectionID)
        _outcome = State(initialValue: workflow.outcome)
        _nextAction = State(initialValue: workflow.nextAction ?? "")
        _hasReviewDate = State(initialValue: workflow.waitingUntil != nil)
        _reviewDate = State(initialValue: Self.parseReviewDate(workflow.waitingUntil) ?? Date().addingTimeInterval(86_400))
    }

    private static func parseReviewDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private var owners: [TodoWorkflow.Owner] {
        var values = [TodoWorkflow.Owner(kind: "user", id: "", label: "You")]
        for person in [workflow.owner] + people where person.kind == "person" {
            if !values.contains(where: { $0.selectionID == person.selectionID }) { values.append(person) }
        }
        return values
    }
    private var selectedOwner: TodoWorkflow.Owner? { owners.first { $0.selectionID == ownerID } }
    private var allowedStates: [String] {
        ["done", "cancelled"].contains(workflow.state) ? [workflow.state, "you_own"] : TodoWorkflow.states
    }
    private var canSave: Bool {
        guard let owner = selectedOwner else { return false }
        return !saving && !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !nextAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (state != "you_own" || owner.kind == "user") && (state != "they_own" || owner.kind == "person")
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Outcome") { TextField("What does done look like?", text: $outcome, axis: .vertical) }
                Section("Current step") {
                    Picker("State", selection: $state) {
                        ForEach(allowedStates, id: \.self) { Text(TodoWorkflow.label(for: $0)).tag($0) }
                    }
                    Picker("Owner", selection: $ownerID) {
                        ForEach(owners, id: \.selectionID) { Text($0.displayName).tag($0.selectionID) }
                    }
                    TextField("What must this owner do next?", text: $nextAction, axis: .vertical)
                    TextField("What changed?", text: $reason, axis: .vertical)
                }
                if state == "waiting" {
                    Section("Follow up") {
                        Toggle("Review on a date", isOn: $hasReviewDate)
                        if hasReviewDate { DatePicker("Review", selection: $reviewDate) }
                        Text("When the date arrives, this returns to you for review. It stays open.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if state == "done" {
                    Section { Text("Saving confirms that the outcome happened. Describe what completed it above.") }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .formStyle(.grouped)
            .navigationTitle("State and owner")
            .disabled(saving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await submit() } }.disabled(!canSave)
                }
            }
            .onChange(of: state) { _, newValue in
                if newValue == "you_own" { ownerID = "user" }
                if newValue == "they_own", selectedOwner?.kind != "person", let person = owners.first(where: { $0.kind == "person" }) {
                    ownerID = person.selectionID
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 440)
        #endif
    }

    @MainActor private func submit() async {
        guard let owner = selectedOwner else { return }
        let wait = state == "waiting" && hasReviewDate ? ISO8601DateFormatter().string(from: reviewDate) : ""
        let candidate = TodoWorkflowChange(state: state, owner: owner, outcome: outcome, nextAction: nextAction,
                                           reason: reason, expectedRevision: workflow.revision, requestID: pendingChange?.requestID ?? UUID().uuidString, waitingUntil: wait)
        // Keep the same request on a transport retry; edited content gets a new ID.
        let change: TodoWorkflowChange
        if let previous = pendingChange, previous != candidate {
            change = TodoWorkflowChange(state: state, owner: owner, outcome: outcome, nextAction: nextAction,
                                        reason: reason, expectedRevision: workflow.revision, requestID: UUID().uuidString, waitingUntil: wait)
        } else { change = candidate }
        pendingChange = change; saving = true; error = nil
        defer { saving = false }
        do { try await save(change); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
