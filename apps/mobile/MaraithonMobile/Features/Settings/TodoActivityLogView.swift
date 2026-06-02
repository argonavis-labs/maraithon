import SwiftUI

struct TodoActivityLogView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var sessionStore
    @State private var events: [MobileAPIClient.RemoteTodoActivity] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    loadingRow
                } else if let errorMessage {
                    ContentUnavailableView(
                        TodoActivityLogCopy.loadFailedTitle,
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else if events.isEmpty {
                    ContentUnavailableView(
                        TodoActivityLogCopy.emptyTitle,
                        systemImage: "clock.arrow.circlepath",
                        description: Text(TodoActivityLogCopy.emptyDescription)
                    )
                } else {
                    Section {
                        ForEach(events) { event in
                            TodoActivityRow(event: event)
                        }
                    }
                }
            }
            .navigationTitle(TodoActivityLogCopy.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await loadActivity() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                    .accessibilityLabel("Refresh Activity")
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
            Text(TodoActivityLogCopy.loadingTitle)
                .foregroundStyle(.secondary)
        }
    }

    private func loadActivity() async {
        guard let sessionToken = sessionStore.user?.sessionToken else {
            events = []
            errorMessage = TodoActivityLogCopy.signedOutMessage
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            events = try await MobileAPIClient().listTodoActivity(sessionToken: sessionToken)
        } catch {
            errorMessage = MobileErrorCopy.message(for: error)
        }

        isLoading = false
    }
}

private struct TodoActivityRow: View {
    let event: MobileAPIClient.RemoteTodoActivity

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: TodoActivityLogCopy.systemImage(for: event))
                .font(.title3)
                .foregroundStyle(TodoActivityLogCopy.tint(for: event))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 5) {
                Text(TodoActivityLogCopy.eventTitle(for: event))
                    .font(.headline)

                Text(TodoActivityLogCopy.todoTitle(for: event))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Label(
                        TodoActivityLogCopy.actorText(for: event),
                        systemImage: TodoActivityLogCopy.actorSystemImage(for: event)
                    )

                    Text(AppFormatters.relativeString(for: event.occurredAt))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

enum TodoActivityLogCopy {
    static let title = "Activity Log"
    static let loadingTitle = "Loading Activity"
    static let loadFailedTitle = "Could Not Load Activity"
    static let emptyTitle = "No Activity"
    static let emptyDescription = "Todo changes will appear here after Maraithon records them."
    static let signedOutMessage = "Sign in to view activity."

    static func eventTitle(for event: MobileAPIClient.RemoteTodoActivity) -> String {
        switch event.eventType {
        case "created":
            "Todo Created"
        case "marked_done":
            "Todo Marked Done"
        case "deleted":
            "Todo Deleted"
        default:
            "Todo Updated"
        }
    }

    static func todoTitle(for event: MobileAPIClient.RemoteTodoActivity) -> String {
        guard let title = event.todoTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else {
            return "Untitled Todo"
        }

        return title
    }

    static func actorText(for event: MobileAPIClient.RemoteTodoActivity) -> String {
        switch event.actorType {
        case "user":
            "User"
        case "agent":
            "Agent"
        default:
            if let label = event.actorLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
               !label.isEmpty
            {
                label
            } else {
                "Unknown"
            }
        }
    }

    static func systemImage(for event: MobileAPIClient.RemoteTodoActivity) -> String {
        switch event.eventType {
        case "created":
            "plus.circle"
        case "marked_done":
            "checkmark.circle"
        case "deleted":
            "trash"
        default:
            "clock.arrow.circlepath"
        }
    }

    static func actorSystemImage(for event: MobileAPIClient.RemoteTodoActivity) -> String {
        event.actorType == "user" ? "person.crop.circle" : "sparkles"
    }

    static func tint(for event: MobileAPIClient.RemoteTodoActivity) -> Color {
        switch event.eventType {
        case "created":
            .blue
        case "marked_done":
            .green
        case "deleted":
            .red
        default:
            .secondary
        }
    }
}
