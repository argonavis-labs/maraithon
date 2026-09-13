/// A todo opens into one focused surface: Maraithon's read and at most two
/// action cards beside a chat pane. Narrow content stacks the work above the
/// chat. The store owns state; the server executes every action.
import SwiftUI
import AssistantProgressKit

struct TodoWorkspaceView: View {
    @Bindable var store: TodoConversationStore
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var showsWorkflow = false
    @State private var showsDetails = false
    @State private var reconnectID = UUID()
    @State private var isChangingStatus = false

    var body: some View {
        VStack(spacing: 0) {
            TodoWorkspaceHeader(
                store: store,
                isChangingStatus: isChangingStatus,
                back: { dismiss() },
                changeStatus: { Task { await changeStatus() } },
                showDetails: { showsDetails = true },
                editWorkflow: { showsWorkflow = true }
            )
            RunnerHairline()
            GeometryReader { space in
                if space.size.width >= Tokens.TodoLayout.twoColumnMinWidth {
                    columns(in: space.size)
                } else {
                    stacked(in: space.size)
                }
            }
        }
        .background(Tokens.Palette.background)
        .navigationTitle("Work on todo")
        .sheet(isPresented: $showsWorkflow) {
            if let workflow = store.todo.workflow {
                TodoWorkflowEditor(workflow: workflow, people: (store.todo.brief?.people ?? []).compactMap {
                    UUID(uuidString: $0.id) == nil ? nil : TodoWorkflow.Owner(kind: "person", id: $0.id, label: $0.name)
                }, save: { try await store.transitionWorkflow($0) })
            }
        }
        .sheet(isPresented: $showsDetails) {
            TodoDetailsSheet(
                store: store,
                isWorking: isChangingStatus,
                changeStatus: { Task { await changeStatus() } },
                dismissTodo: { Task { await dismissTodo() } }
            )
        }
        .task(id: reconnectID) { await store.connectAndObserve() }
        .onDisappear { Task { await env.todos.load() } }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private func columns(in size: CGSize) -> some View {
        let chatWidth = min(max(size.width * Tokens.TodoLayout.chatPaneFraction, Tokens.TodoLayout.chatPaneMinWidth),
                            Tokens.TodoLayout.chatPaneMaxWidth)
        return HStack(spacing: 0) {
            ScrollView {
                TodoWorkColumn(store: store)
            }
            .frame(minWidth: Tokens.TodoLayout.workColumnMinWidth, maxWidth: .infinity, maxHeight: .infinity)
            Rectangle()
                .fill(Tokens.Palette.border)
                .frame(width: Tokens.Stroke.hairline)
                .accessibilityHidden(true)
            TodoChatPane(store: store, reconnect: { reconnectID = UUID() })
                .frame(width: chatWidth)
        }
    }

    private func stacked(in size: CGSize) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                TodoWorkColumn(store: store)
            }
            .frame(height: size.height * Tokens.TodoLayout.stackedWorkFraction)
            RunnerHairline()
            TodoChatPane(store: store, reconnect: { reconnectID = UUID() })
        }
    }

    private func changeStatus() async {
        isChangingStatus = true
        defer { isChangingStatus = false }
        await env.todos.performPrimaryAction(on: store.todo)
        await store.refreshTodo()
    }

    private func dismissTodo() async {
        isChangingStatus = true
        defer { isChangingStatus = false }
        await env.todos.perform(.dismiss, on: store.todo)
        await store.refreshTodo()
    }
}
