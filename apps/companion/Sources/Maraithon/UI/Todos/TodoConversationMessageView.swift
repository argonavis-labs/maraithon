/// One conversation turn exposes readable content, grounded drafts, and optional source activity.
import SwiftUI

struct TodoConversationMessageView: View {
    let message: CompanionConversation.Message
    let store: TodoConversationStore

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            Label(message.role == "user" ? "You" : "Maraithon",
                  systemImage: message.role == "user" ? "person.crop.circle" : "sparkle")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if message.messageClass != "todo_chat_primer" {
                Text(.init(message.body)).textSelection(.enabled)
            } else if message.structuredData?.draftCard == nil {
                Text(store.todo.brief?.summary ?? store.todo.summary ?? message.body).textSelection(.enabled)
            }
            if let card = message.structuredData?.draftCard {
                Label(card.isEditable
                      ? "\(card.title ?? "Draft") · Review in next actions above"
                      : "\(card.title ?? "Action") · \(card.status ?? "Updated")",
                      systemImage: "doc.text").font(.callout).foregroundStyle(.secondary)
            } else {
                actions
            }
            if let work = message.workSummary, let tools = work.toolCalls, !tools.isEmpty {
                DisclosureGroup(work.headline ?? "Context consulted") {
                    ForEach(tools.indices, id: \.self) { index in
                        if let label = tools[index].label {
                            VStack(alignment: .leading, spacing: Tokens.Spacing.xsmall) {
                                Label(label, systemImage: tools[index].status == "failed" ? "exclamationmark.triangle" : "checkmark")
                                if let summary = tools[index].summary { Text(summary).textSelection(.enabled) }
                                if let detail = tools[index].detail { Text(detail).foregroundStyle(.tertiary) }
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        ForEach(message.actions.indices, id: \.self) { index in
            let action = message.actions[index]
            if action.kind == "prepared_action_decision" {
                Button(action.label) {
                    Task { await store.decide(id: action.id, decision: action.decision, edits: [:]) }
                }.disabled(store.decidingActionID != nil)
            }
        }
    }
}
