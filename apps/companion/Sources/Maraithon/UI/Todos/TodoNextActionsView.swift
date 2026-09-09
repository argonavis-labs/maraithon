/// Runner-style action shelf: specific next moves stay above chat and expand into provider review.
import SwiftUI

struct TodoNextActionsView: View {
    let store: TodoConversationStore
    let compact: Bool
    @Binding var expandedMessageID: String?

    private var actions: [CompanionTodoWorkspace.Action] {
        let suggested = store.todo.brief?.suggestedActions ?? []
        return suggested.filter { $0.provider == "calendar" } + suggested.filter { $0.provider != "calendar" }
    }

    private var drafts: [CompanionConversation.Message] {
        (store.thread?.messages ?? []).filter {
            guard let card = $0.structuredData?.draftCard else { return false }
            return card.isEditable || card.provider == "browser"
        }
    }

    private func actionButton(_ action: CompanionTodoWorkspace.Action) -> some View {
        Button { Task { await store.send(action.request) } } label: {
            HStack(alignment: .top, spacing: Tokens.Spacing.small) {
                TodoProviderMark(provider: action.provider)
                VStack(alignment: .leading, spacing: Tokens.Spacing.xsmall) {
                    Text(action.label).font(.callout.weight(.medium))
                    Text(action.purpose).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(Tokens.Spacing.small).contentShape(Rectangle())
        }.buttonStyle(.bordered)
            .disabled(store.thread == nil || store.isSending || store.pendingMessage != nil || store.isThinking)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            if let summary = store.todo.brief?.summary {
                Text(summary).font(.callout).textSelection(.enabled)
            }
            if let outcome = store.todo.brief?.doneWhen {
                Text("Done when: \(outcome)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let questions = store.todo.brief?.openQuestions, !questions.isEmpty {
                Text("Your decision").font(.callout.weight(.semibold))
                ForEach(questions, id: \.self) { Text($0).font(.callout).textSelection(.enabled) }
            }
            if store.todo.canMarkDone {
                Button("Prepare this for me", systemImage: "sparkles") {
                    Task { await store.send("Prepare this todo for me. Gather the context, work through the next useful steps, and bring back a concrete action to review or the one decision you need from me.") }
                }.buttonStyle(.borderedProminent)
                    .disabled(store.thread == nil || store.isSending || store.pendingMessage != nil || store.isThinking)
            }
            if !actions.isEmpty && store.todo.canMarkDone {
                Text("Suggested next actions").font(.headline)
                if compact {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
                        ForEach(actions) { action in actionButton(action) }
                    }
                } else {
                    HStack(alignment: .top, spacing: Tokens.Spacing.small) {
                        ForEach(actions) { action in actionButton(action).frame(maxWidth: .infinity) }
                    }
                }
            } else if store.todo.brief == nil {
                Text("Source context is not ready yet. You can ask Maraithon to prepare the work.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(drafts) { message in
                if let card = message.structuredData?.draftCard {
                    DisclosureGroup(isExpanded: Binding(
                        get: { expandedMessageID == message.id },
                        set: { expandedMessageID = $0 ? message.id : nil }
                    )) {
                        TodoConversationDraftView(draft: card, store: store, messageID: message.id)
                            .id(message.id + (card.preparedActionID ?? "draft"))
                    } label: {
                        HStack(spacing: Tokens.Spacing.small) {
                            TodoProviderMark(provider: card.provider)
                            Text(card.title ?? "Prepared draft").font(.callout.weight(.medium))
                            Spacer()
                            Text(card.status ?? "Ready for review").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Tokens.Spacing.large)
        .padding(.vertical, Tokens.Spacing.medium)
        .onChange(of: drafts.last?.id) { _, newValue in expandedMessageID = newValue }
    }
}
