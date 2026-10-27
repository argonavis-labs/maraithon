import SwiftUI

/// Live feed of work-item activity: items added to the list and items
/// checked off, whether the user did it or Maraithon closed them from
/// source evidence. Auto-completions show the evidence note inline.
struct StreamView: View {
    @Environment(SessionStore.self) private var sessionStore
    @State private var events: [MobileAPIClient.RemoteTodoActivity] = []
    @State private var filter: StreamFilter = .all
    @State private var isLoading = true
    @State private var errorMessage: String?
    /// Regrouping and sorting run only when the events or the filter change,
    /// not on every body pass.
    @State private var filteredDays: [StreamDay] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 0) {
                        RunnerPageHeader(title: StreamCopy.title, count: events.isEmpty ? nil : events.count)
                            .padding(.horizontal, Runner.Layout.pageInset)

                        RunnerTabs(
                            items: StreamFilter.allCases.map { RunnerTabs.Item(id: $0, title: $0.title) },
                            selection: $filter
                        )
                        .accessibilityLabel(StreamCopy.filterLabel)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: Runner.Spacing.small, leading: 0, bottom: 0, trailing: 0))
                }

                if isLoading && events.isEmpty {
                    ThemedListSection {
                        ThemedLoadingRow(title: StreamCopy.loadingTitle)
                    }
                } else if let errorMessage, events.isEmpty {
                    ThemedListSection {
                        RunnerEmptyState(
                            title: StreamCopy.loadFailedTitle,
                            description: errorMessage,
                            systemImage: "exclamationmark.triangle"
                        )
                        .listRowSeparator(.hidden)
                    }
                } else if filteredDays.isEmpty {
                    ThemedListSection {
                        RunnerEmptyState(
                            title: StreamCopy.emptyTitle,
                            description: StreamCopy.emptyDescription,
                            systemImage: "wave.3.right"
                        )
                        .listRowSeparator(.hidden)
                    }
                } else {
                    ForEach(filteredDays) { day in
                        ThemedListSection(day.title) {
                            ForEach(day.events) { event in
                                StreamRow(event: event)
                            }
                        }
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .runnerPage()
            .task {
                await loadActivity()
            }
            .refreshable {
                await loadActivity()
            }
            .onChange(of: filter) { _, _ in
                rebuildFilteredDays()
            }
        }
    }

    private func rebuildFilteredDays() {
        filteredDays = StreamDay.group(events: events.filter(filter.matches))
    }

    private func loadActivity() async {
        guard let sessionToken = sessionStore.user?.sessionToken else {
            events = []
            errorMessage = StreamCopy.signedOutMessage
            isLoading = false
            rebuildFilteredDays()
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            events = try await MobileAPIClient().listTodoActivity(sessionToken: sessionToken, limit: 200)
        } catch {
            errorMessage = MobileErrorCopy.message(for: error)
        }

        isLoading = false
        rebuildFilteredDays()
    }
}

enum StreamFilter: String, CaseIterable, Identifiable {
    case all
    case added
    case completed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .added: "Added"
        case .completed: "Done"
        }
    }

    func matches(_ event: MobileAPIClient.RemoteTodoActivity) -> Bool {
        switch self {
        case .all: true
        case .added: event.eventType == "created"
        case .completed: event.eventType == "marked_done"
        }
    }
}

/// One calendar day of activity, newest day first.
struct StreamDay: Identifiable {
    let id: Date
    let title: String
    let events: [MobileAPIClient.RemoteTodoActivity]

    static func group(events: [MobileAPIClient.RemoteTodoActivity]) -> [StreamDay] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: events) { event in
            calendar.startOfDay(for: event.occurredAt)
        }

        return grouped.keys.sorted(by: >).map { day in
            StreamDay(
                id: day,
                title: StreamCopy.dayTitle(for: day),
                events: (grouped[day] ?? []).sorted { $0.occurredAt > $1.occurredAt }
            )
        }
    }
}

private struct StreamRow: View {
    let event: MobileAPIClient.RemoteTodoActivity

    var body: some View {
        HStack(alignment: .top, spacing: Runner.Spacing.tight) {
            Image(systemName: TodoActivityLogCopy.systemImage(for: event))
                .font(Runner.Typography.icon)
                .foregroundStyle(TodoActivityLogCopy.tint(for: event))
                .frame(width: Runner.Spacing.large)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Runner.Spacing.xsmall) {
                Text(TodoActivityLogCopy.todoTitle(for: event))
                    .font(Runner.Typography.bodyMedium)
                    .foregroundStyle(Runner.Palette.foreground)
                    .lineLimit(2)

                if let note = StreamCopy.note(for: event) {
                    Text(note)
                        .font(Runner.Typography.small)
                        .foregroundStyle(Runner.Palette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: Runner.Spacing.compact) {
                    Label(
                        StreamCopy.actorPhrase(for: event),
                        systemImage: TodoActivityLogCopy.actorSystemImage(for: event)
                    )

                    Text("·")

                    Text(event.occurredAt.formatted(date: .omitted, time: .shortened))
                }
                .font(Runner.Typography.caption)
                .foregroundStyle(Runner.Palette.mutedForeground)
                .lineLimit(1)
            }
        }
        .padding(.vertical, Runner.Spacing.xxsmall)
    }
}

enum StreamCopy {
    static let title = "Stream"
    static let filterLabel = "Show"
    static let loadingTitle = "Loading the stream"
    static let loadFailedTitle = "Could Not Load the Stream"
    static let emptyTitle = "Nothing Here Yet"
    static let emptyDescription = "New work items and completed ones will appear here as they happen."
    static let signedOutMessage = "Sign in to see your stream."

    static func actorPhrase(for event: MobileAPIClient.RemoteTodoActivity) -> String {
        let actor = event.actorType == "user" ? "You" : "Maraithon"

        switch event.eventType {
        case "created": return "\(actor) added this"
        case "marked_done": return "\(actor) checked this off"
        case "deleted": return "\(actor) removed this"
        default: return "\(actor) updated this"
        }
    }

    /// Resolution note recorded with the event — for auto-completions this
    /// is the cross-channel evidence quote.
    static func note(for event: MobileAPIClient.RemoteTodoActivity) -> String? {
        guard let note = event.metadata["note"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !note.isEmpty else {
            return nil
        }
        return note
    }

    private static let dayTitleStyle: Date.FormatStyle = .dateTime.weekday(.wide).month(.abbreviated).day()

    static func dayTitle(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(dayTitleStyle)
    }
}
