import SwiftUI
import AssistantProgressKit

struct TodoWorkspaceHeader: View {
    let todo: TodoItem
    let summary: String
    let actionsDisabled: Bool
    let isUpdating: Bool
    let send: (String) -> Void
    let complete: () -> Void
    let reopen: () -> Void
    let showPeople: () -> Void
    let showWorkflow: () -> Void
    let sourceSend: (String, String?) async throws -> Void
    @State private var showsFullSummary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ProviderMark(provider: todo.sourceProviderLabel?.lowercased() ?? todo.sourceProvider ?? todo.sourceSystem ?? "")
                Text(todo.sourceProviderLabel ?? todo.sourceSystem ?? "Todo")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if let people = todo.todoBrief?.people, !people.isEmpty {
                    Button(action: showPeople) {
                        Label("\(people.count) people", systemImage: "person.2")
                            .font(.subheadline)
                    }
                }
            }
            Text(todo.title).font(.title2.bold()).textSelection(.enabled)
            if let workflow = todo.workflow {
                HStack {
                    TodoOwnershipLabel(workflow: workflow).font(.subheadline)
                    Spacer()
                    Button("Change", action: showWorkflow).font(.subheadline)
                }
                Text("Outcome: \(workflow.outcome)").font(.subheadline).foregroundStyle(.secondary)
                if let next = workflow.nextAction { Text("Next: \(next)").font(.subheadline) }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(showsFullSummary ? nil : 3).textSelection(.enabled)
                if summary.count > 150 {
                    Button(showsFullSummary ? "Less context" : "More context") { showsFullSummary.toggle() }
                        .font(.caption)
                }
            }

            HStack {
                if todo.isActive {
                    Button("Mark done", systemImage: "checkmark.circle", action: complete)
                        .disabled(isUpdating)
                } else if todo.isCompleted {
                    Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Reopen", action: reopen).disabled(isUpdating)
                }
                if let call = todo.todoBrief?.call, let url = call.url, todo.isActive {
                    Link(destination: url) { Label("Call " + call.label, systemImage: "phone") }
                }
            }.buttonStyle(.bordered)

            if todo.isActive {
                if let outcome = todo.todoBrief?.doneWhen {
                    Text("Done when: \(outcome)").font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let questions = todo.todoBrief?.openQuestions, !questions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your decision").font(.subheadline.weight(.semibold))
                        ForEach(questions, id: \.self) { Text($0).font(.subheadline).textSelection(.enabled) }
                    }
                }
                Button("Prepare this for me", systemImage: "sparkles") {
                    send("Prepare this todo for me. Gather the context, work through the next useful steps, and bring back a concrete action to review or the one decision you need from me.")
                }.buttonStyle(.borderedProminent).disabled(actionsDisabled)
                VStack(alignment: .leading, spacing: 0) {
                    if let actions = todo.todoBrief?.suggestedActions, !actions.isEmpty {
                        Text("Suggested next actions")
                            .font(.subheadline.weight(.semibold))
                            .padding(.bottom, 6)
                        ForEach(actions) { action in
                            Button { send(action.request) } label: {
                                HStack(spacing: 10) {
                                    ProviderMark(provider: action.provider)
                                    Text(action.label).font(.subheadline).multilineTextAlignment(.leading)
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }.padding(.vertical, 9).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(actionsDisabled)
                            .accessibilityIdentifier("todo-next-action-\(action.id)")
                        }
                    }
                }
            }

            if let action = todo.sourceAction {
                DisclosureGroup {
                    SourceActionCardView(action: action, showsContext: false, onSend: sourceSend)
                        .padding(.top, 8)
                } label: {
                    Label("Source and suggested reply", systemImage: "text.bubble")
                        .font(.subheadline)
                }
            }
            Divider()
            Label("Conversation", systemImage: "bubble.left.and.bubble.right")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 8)
    }
}
