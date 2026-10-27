/// Quick capture creates an accepted manual todo while leaving Triage open.
import SwiftUI
import AssistantProgressKit

struct TodosQuickEntry: View {
    let store: TodosStore

    var body: some View {
        TodoQuickEntry(focusChanged: { store.quickEntryFocused = $0 }) { title, id in
            _ = try await store.create(CompanionTodoDraft(requestID: id,
                title: title, notes: nil, nextAction: title, priority: 50, dueAt: nil),
                stayInTriage: true)
        }
        .padding(.vertical, Tokens.Spacing.medium)
    }
}
