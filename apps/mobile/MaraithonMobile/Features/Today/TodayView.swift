import SwiftData
import SwiftUI

struct TodayView: View {
    @Environment(AppNavigation.self) private var appNavigation
    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TodoItem.createdAt, order: .reverse) private var todos: [TodoItem]
    @Query(sort: \CRMContact.name) private var contacts: [CRMContact]
    @Query(sort: \ChatThread.updatedAt, order: .reverse) private var threads: [ChatThread]
    @State private var editingTodo: TodoItem?
    @State private var refreshErrorMessage: String?
    @State private var isRefreshing = false

    private var metrics: TodayMetrics {
        TodayInsightEngine.metrics(todos: todos, contacts: contacts)
    }

    private var brief: TodayBrief {
        TodayInsightEngine.brief(todos: todos, contacts: contacts)
    }

    private var focusItems: [TodayFocusItem] {
        TodayInsightEngine.focusQueue(todos: todos, contacts: contacts)
    }

    private var recentThreads: [ChatThread] {
        Array(threads.prefix(3))
    }

    var body: some View {
        NavigationStack {
            List {
                if let refreshErrorMessage {
                    Section {
                        SyncIssueBanner(
                            message: refreshErrorMessage,
                            retry: { Task { await refreshLatestData() } },
                            dismiss: { self.refreshErrorMessage = nil }
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                    }
                }

                Section {
                    TodayBriefCard(
                        greeting: greeting,
                        brief: brief
                    ) {
                        navigate(to: brief.destination)
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 6, trailing: 16))
                .listRowSeparator(.hidden)

                Section("Ask Maraithon") {
                    ChiefOfStaffPromptShelf(prompts: ChiefOfStaffPrompt.today) { prompt in
                        appNavigation.showChat(prompt: prompt.message)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 6, trailing: 0))
                    .listRowSeparator(.hidden)
                }

                Section(TodayViewCopy.snapshotSectionTitle) {
                    VStack(spacing: 1) {
                        CommandRow(
                            title: TodayViewCopy.openWorkTitle,
                            subtitle: TodayViewCopy.openWorkSubtitle,
                            value: "\(metrics.openTodos)",
                            systemImage: "circle",
                            tint: .blue
                        ) {
                            appNavigation.showTodos(.open)
                        }
                        Divider().padding(.leading, 48)
                        CommandRow(
                            title: TodayViewCopy.overdueTitle,
                            subtitle: TodayViewCopy.overdueSubtitle,
                            value: "\(metrics.overdueTodos)",
                            systemImage: "clock.badge.exclamationmark",
                            tint: .orange
                        ) {
                            appNavigation.showTodos(.overdue)
                        }
                        Divider().padding(.leading, 48)
                        CommandRow(
                            title: TodayViewCopy.dueTodayTitle,
                            subtitle: TodayViewCopy.dueTodaySubtitle,
                            value: "\(metrics.dueTodayTodos)",
                            systemImage: "calendar.badge.clock",
                            tint: .indigo
                        ) {
                            appNavigation.showTodos(.today)
                        }
                        Divider().padding(.leading, 48)
                        CommandRow(
                            title: TodayViewCopy.peopleTitle,
                            subtitle: TodayViewCopy.peopleSubtitle,
                            value: "\(metrics.peopleCount)",
                            systemImage: "person.2.fill",
                            tint: .green
                        ) {
                            appNavigation.showPeople(.all)
                        }
                        Divider().padding(.leading, 48)
                        CommandRow(
                            title: TodayViewCopy.followUpTitle,
                            subtitle: TodayViewCopy.followUpSubtitle,
                            value: "\(metrics.atRiskContacts)",
                            systemImage: "person.crop.circle.badge.exclamationmark",
                            tint: .red
                        ) {
                            appNavigation.showPeople(.atRisk)
                        }
                    }
                    .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowSeparator(.hidden)
                }

                Section(TodayViewCopy.focusSectionTitle) {
                    if focusItems.isEmpty {
                        ContentUnavailableView(
                            TodayViewCopy.emptyFocusTitle,
                            systemImage: "sparkles",
                            description: Text(TodayViewCopy.emptyFocusDescription)
                        )
                    } else {
                        ForEach(focusItems) { item in
                            focusRow(for: item)
                        }
                    }
                }

                Section(TodayViewCopy.recentChatsSectionTitle) {
                    if recentThreads.isEmpty {
                        ContentUnavailableView(
                            TodayViewCopy.emptyRecentChatsTitle,
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text(TodayViewCopy.emptyRecentChatsDescription)
                        )
                    } else {
                        ForEach(recentThreads) { thread in
                            NavigationLink {
                                ChatDetailView(thread: thread)
                            } label: {
                                ChatThreadRow(thread: thread)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.inline)
            .contentMargins(.top, 0, for: .scrollContent)
            .listSectionSpacing(12)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AccountMenuButton()
                }
            }
            .sheet(item: $editingTodo) { todo in
                TodoEditorView(todo: todo)
            }
            .task {
                await refreshLatestData()
            }
        }
    }

    private func refreshLatestData() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            try await ProductionDataSync.refreshAll(
                sessionStore: sessionStore,
                modelContext: modelContext
            )
            refreshErrorMessage = nil
        } catch {
            refreshErrorMessage = "Could not refresh your latest brief. \(MobileErrorCopy.message(for: error))"
        }
    }

    private func navigate(to destination: TodayDestination) {
        switch destination {
        case .todos(let filter):
            appNavigation.showTodos(filter)
        case .people(let filter):
            appNavigation.showPeople(filter)
        case .chat:
            appNavigation.showChat()
        }
    }

    @ViewBuilder
    private func focusRow(for item: TodayFocusItem) -> some View {
        switch item.kind {
        case .todo:
            if let todo = todo(for: item) {
                Button {
                    editingTodo = todo
                } label: {
                    TodayFocusRow(item: item)
                }
                .buttonStyle(.plain)
            } else {
                TodayFocusRow(item: item)
            }
        case .contact:
            if let contact = contact(for: item) {
                NavigationLink {
                    ContactDetailView(contact: contact)
                } label: {
                    TodayFocusRow(item: item)
                }
            } else {
                TodayFocusRow(item: item)
            }
        }
    }

    private func todo(for item: TodayFocusItem) -> TodoItem? {
        todos.first { $0.id == item.referenceID }
    }

    private func contact(for item: TodayFocusItem) -> CRMContact? {
        contacts.first { $0.id == item.referenceID }
    }

    private var greeting: String {
        let name = sessionStore.user?.email
            .split(separator: "@")
            .first
            .map(String.init)?
            .replacingOccurrences(of: ".", with: " ")
            .capitalized

        if let name, !name.isEmpty {
            return "Good \(daypart), \(name)"
        }

        return "Good \(daypart)"
    }

    private var daypart: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:
            return "morning"
        case 12..<17:
            return "afternoon"
        default:
            return "evening"
        }
    }
}

enum TodayViewCopy {
    static let snapshotSectionTitle = "Priority Snapshot"
    static let focusSectionTitle = "Focus queue"
    static let recentChatsSectionTitle = "Recent chats"
    static let openWorkTitle = "Open work"
    static let openWorkSubtitle = "Unfinished items"
    static let overdueTitle = "Past due"
    static let overdueSubtitle = "Needs action"
    static let dueTodayTitle = "Due today"
    static let dueTodaySubtitle = "Before tomorrow"
    static let peopleTitle = "People"
    static let peopleSubtitle = "Relationships tracked"
    static let followUpTitle = "Needs follow-up"
    static let followUpSubtitle = "Relationships need attention"
    static let emptyFocusTitle = "Nothing urgent"
    static let emptyFocusDescription = "No past-due work or relationship follow-ups need attention."
    static let emptyRecentChatsTitle = "No recent chats"
    static let emptyRecentChatsDescription = "Start a chat when you need a draft, summary, or prioritization pass."

    static var snapshotLabels: [String] {
        [
            snapshotSectionTitle,
            focusSectionTitle,
            recentChatsSectionTitle,
            openWorkTitle,
            openWorkSubtitle,
            overdueTitle,
            overdueSubtitle,
            dueTodayTitle,
            dueTodaySubtitle,
            peopleTitle,
            peopleSubtitle,
            followUpTitle,
            followUpSubtitle,
            emptyFocusTitle,
            emptyFocusDescription,
            emptyRecentChatsTitle,
            emptyRecentChatsDescription
        ]
    }
}

private struct ChiefOfStaffPromptShelf: View {
    let prompts: [ChiefOfStaffPrompt]
    let action: (ChiefOfStaffPrompt) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(prompts) { prompt in
                    Button {
                        action(prompt)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: prompt.systemImage)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(prompt.tint)
                                .frame(width: 32, height: 32)
                                .background(prompt.tint.opacity(0.12), in: Circle())

                            VStack(alignment: .leading, spacing: 3) {
                                Text(prompt.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Text(prompt.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .frame(width: 182, alignment: .leading)
                        .padding(12)
                        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color(uiColor: .separator).opacity(0.18), lineWidth: 1)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(prompt.title). \(prompt.subtitle)")
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }
}

private struct TodayBriefCard: View {
    let greeting: String
    let brief: TodayBrief
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: brief.systemImage)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor, in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(brief.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Text(brief.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(brief.title). \(brief.subtitle)")
        .accessibilityHint(brief.actionTitle)
    }
}

private struct TodayFocusRow: View {
    let item: TodayFocusItem

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)

                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } icon: {
            Image(systemName: item.systemImage)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 28)
        }
        .padding(.vertical, 4)
    }

    private var tint: Color {
        switch item.kind {
        case .todo: .orange
        case .contact: .red
        }
    }
}
