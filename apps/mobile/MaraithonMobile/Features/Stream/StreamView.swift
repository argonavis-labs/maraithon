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

    var body: some View {
        NavigationStack {
            List {
                if isLoading && events.isEmpty {
                    loadingRow
                } else if let errorMessage, events.isEmpty {
                    ContentUnavailableView(
                        StreamCopy.loadFailedTitle,
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else if filteredDays.isEmpty {
                    ContentUnavailableView(
                        StreamCopy.emptyTitle,
                        systemImage: "wave.3.right",
                        description: Text(StreamCopy.emptyDescription)
                    )
                } else {
                    ForEach(filteredDays) { day in
                        Section(day.title) {
                            ForEach(day.events) { event in
                                StreamRow(event: event)
                            }
                        }
                    }
                }
            }
            .navigationTitle(StreamCopy.title)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker(StreamCopy.filterLabel, selection: $filter) {
                        ForEach(StreamFilter.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                }
            }
            .task {
                await loadActivity()
            }
            .refreshable {
                await loadActivity()
            }
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(StreamCopy.loadingTitle)
                .foregroundStyle(.secondary)
        }
    }

    private var filteredDays: [StreamDay] {
        StreamDay.group(events: events.filter(filter.matches))
    }

    private func loadActivity() async {
        guard let sessionToken = sessionStore.user?.sessionToken else {
            events = []
            errorMessage = StreamCopy.signedOutMessage
            isLoading = false
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
    let id: String
    let title: String
    let events: [MobileAPIClient.RemoteTodoActivity]

    static func group(events: [MobileAPIClient.RemoteTodoActivity]) -> [StreamDay] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: events) { event in
            calendar.startOfDay(for: event.occurredAt)
        }

        return grouped.keys.sorted(by: >).map { day in
            StreamDay(
                id: day.formatted(.iso8601),
                title: StreamCopy.dayTitle(for: day),
                events: (grouped[day] ?? []).sorted { $0.occurredAt > $1.occurredAt }
            )
        }
    }
}

private struct StreamRow: View {
    let event: MobileAPIClient.RemoteTodoActivity

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: TodoActivityLogCopy.systemImage(for: event))
                .font(.title3)
                .foregroundStyle(TodoActivityLogCopy.tint(for: event))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(TodoActivityLogCopy.todoTitle(for: event))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)

                if let note = StreamCopy.note(for: event) {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 6) {
                    Label(
                        StreamCopy.actorPhrase(for: event),
                        systemImage: TodoActivityLogCopy.actorSystemImage(for: event)
                    )

                    Text("·")

                    Text(event.occurredAt.formatted(date: .omitted, time: .shortened))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
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

    static func dayTitle(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}
