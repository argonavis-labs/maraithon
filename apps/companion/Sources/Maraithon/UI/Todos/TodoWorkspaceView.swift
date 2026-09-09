/// A todo opens into actionable context: next moves above chat, and people beside the work.
import SwiftUI
import AssistantProgressKit

struct TodoWorkspaceView: View {
    @Bindable var store: TodoConversationStore
    @Environment(AppEnvironment.self) private var env
    @State private var showsWorkflow = false
    @State private var detailsShown = false
    @State private var peopleShown = true
    @State private var reconnectID = UUID()
    @State private var isChangingStatus = false
    @State private var expandedActionMessageID: String?
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                GeometryReader { space in
                VStack(spacing: 0) {
                    ScrollView {
                        TodoNextActionsView(store: store, compact: space.size.width < Tokens.Layout.todoActionsHorizontalMinWidth,
                                            expandedMessageID: $expandedActionMessageID)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(height: actionShelfHeight(in: space.size))
                    Divider()
                    conversation
                    if let notice = store.connectionNotice {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, Tokens.Spacing.large)
                    }
                    if let error = store.error, store.thread != nil {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.red)
                            .padding(.horizontal, Tokens.Spacing.large).textSelection(.enabled)
                    }
                    Divider()
                    composer
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(minWidth: Tokens.Layout.todoChatMinWidth)
                if peopleShown {
                    TodoPeopleSidebar(store: store, showsDetails: $detailsShown, details: AnyView(details))
                }
            }
        }
        .sheet(isPresented: $showsWorkflow) {
            if let workflow = store.todo.workflow {
                TodoWorkflowEditor(workflow: workflow, people: (store.todo.brief?.people ?? []).compactMap {
                    UUID(uuidString: $0.id) == nil ? nil : TodoWorkflow.Owner(kind: "person", id: $0.id, label: $0.name)
                }, save: { try await store.transitionWorkflow($0) })
            }
        }
        .navigationTitle("Work on todo")
        .toolbar { Button("People & details", systemImage: "sidebar.right") { peopleShown.toggle() } }
        .task(id: reconnectID) { await store.connectAndObserve() }
        .onDisappear { Task { await env.todos.load() } }
    }

    @ViewBuilder private var conversation: some View {
        if store.isLoading && store.thread == nil {
            ProgressView("Gathering this todo’s context…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.thread == nil {
            ContentUnavailableView {
                Label("Conversation could not load", systemImage: "bubble.left.and.exclamationmark.bubble.right")
            } description: { Text(store.error ?? "Reconnect to continue this todo.") } actions: {
                Button("Retry", systemImage: "arrow.clockwise") { reconnectID = UUID() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TodoConversationTimeline(store: store)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            HStack(alignment: .top, spacing: Tokens.Spacing.medium) {
                Text(store.todo.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                Spacer(minLength: Tokens.Spacing.small)
                Button(store.todo.canReopen ? "Reopen" : "Mark done", systemImage: "checkmark") {
                    Task { await changeStatus() }
                }.buttonStyle(.borderedProminent)
                    .disabled(isChangingStatus || (!store.todo.canMarkDone && !store.todo.canReopen))
                Menu {
                    if let source = store.todo.actionCard?.sourceAction, let url = source.destination {
                        Link(source.openLabel ?? "Open original", destination: url)
                    }
                    Button("Todo details", systemImage: "info.circle") { detailsShown = true; peopleShown = true }
                    Button("Dismiss todo", systemImage: "xmark.circle") {
                        Task { await env.todos.perform(.dismiss, on: store.todo); await store.refreshTodo() }
                    }.disabled(isChangingStatus || !store.todo.canMarkDone)
                } label: { Label("More", systemImage: "ellipsis") }
            }
            HStack(spacing: Tokens.Spacing.small) {
                TodoProviderMark(provider: store.todo.source)
                Text(TodosCopy.sourceLabel(store.todo.source))
                Text("·")
                Text(store.todo.workflow?.label ?? TodosCopy.statusLabel(store.todo.status))
                Text("·")
                Text(TodosCopy.dueLabel(store.todo.dueDate, active: store.todo.canMarkDone))
            }.font(.caption).foregroundStyle(.secondary)
            if let workflow = store.todo.workflow {
                HStack {
                    TodoOwnershipLabel(workflow: workflow, showsState: false)
                    Button("Change state or owner") { showsWorkflow = true }.buttonStyle(.borderless)
                }.font(.callout)
                Text("Outcome: \(workflow.outcome)").font(.callout).foregroundStyle(.secondary)
            }
            if let next = store.todo.recommendedMove, store.todo.canMarkDone {
                Text(next).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
        }.padding(Tokens.Spacing.large).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var details: some View {
        TodoDetailView(todo: store.todo, isWorking: isChangingStatus, isLoadingDetails: false,
            detailError: nil, primaryAction: { Task { await changeStatus() } },
            dismissAction: { Task { await env.todos.perform(.dismiss, on: store.todo); await store.refreshTodo() } },
            retryDetails: { Task { await store.refreshTodo() } })
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            HStack(alignment: .bottom, spacing: Tokens.Spacing.small) {
                TextField("Talk to this todo…", text: $store.composer, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...6).focused($composerFocused)
                    .accessibilityLabel("Message Maraithon about this todo")
                Button("Send", systemImage: "arrow.up") { Task { await store.send() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(store.thread == nil || store.isSending || store.pendingMessage != nil || store.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("⌘ Return to send").font(.caption).foregroundStyle(.tertiary)
        }.frame(maxWidth: Tokens.Layout.todoConversationWidth)
            .frame(maxWidth: .infinity).padding(Tokens.Spacing.medium)
    }

    private func actionShelfHeight(in size: CGSize) -> CGFloat {
        let draftCount = (store.thread?.messages ?? []).filter { $0.structuredData?.draftCard != nil }.count
        let actionCount = max(store.todo.brief?.suggestedActions?.count ?? 0, 1)
        let rows = size.width < Tokens.Layout.todoActionsHorizontalMinWidth ? actionCount : 1
        let collapsed = Tokens.Layout.todoWorkReadHeight + Tokens.Layout.todoActionShelfHeadingHeight
            + CGFloat(rows) * Tokens.Layout.todoActionRowHeight
            + CGFloat(draftCount) * Tokens.Layout.todoDraftHeaderHeight
        let expanded = expandedActionMessageID != nil
        return min(expanded ? Tokens.Layout.todoActionShelfMaxHeight : collapsed,
                   size.height * (expanded ? 0.60 : 0.55))
    }

    private func changeStatus() async {
        isChangingStatus = true
        defer { isChangingStatus = false }
        await env.todos.performPrimaryAction(on: store.todo)
        await store.refreshTodo()
    }
}
