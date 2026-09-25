/// Fast capture from anywhere in the Mac app. Saving keeps the current view
/// and leaves preparation to the server's durable background queue.
import SwiftUI
import AssistantProgressKit

struct QuickTodoView: View {
    let store: TodosStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.medium) {
            Text("Add a Todo").font(.title2.weight(.semibold))
            TodoQuickEntry(autofocus: true) { title, id in
                _ = try await store.create(CompanionTodoDraft(requestID: id,
                    title: title, notes: nil, nextAction: title, priority: 50, dueAt: nil),
                    stayInTriage: true)
                dismiss()
            }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(Tokens.Spacing.large)
        .frame(width: Tokens.Layout.todoEditorWidth)
    }
}
