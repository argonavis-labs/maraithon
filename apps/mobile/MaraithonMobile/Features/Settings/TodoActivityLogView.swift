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
                ThemedListHeader {
                    RunnerPageHeader(title: TodoActivityLogCopy.title, count: events.isEmpty ? nil : events.count)
                }

                if isLoading {
                    ThemedListSection {
                        ThemedLoadingRow(title: TodoActivityLogCopy.loadingTitle)
                    }
                } else if let errorMessage {
                    ThemedListSection {
                        RunnerEmptyState(
                            title: TodoActivityLogCopy.loadFailedTitle,
                            description: errorMessage,
                            systemImage: "exclamationmark.triangle"
                        )
                        .listRowSeparator(.hidden)
                    }
                } else if events.isEmpty {
                    ThemedListSection {
                        RunnerEmptyState(
                            title: TodoActivityLogCopy.emptyTitle,
                            description: TodoActivityLogCopy.emptyDescription,
                            systemImage: "clock.arrow.circlepath"
                        )
                        .listRowSeparator(.hidden)
                    }
                } else {
                    ThemedListSection {
                        ForEach(events) { event in
                            TodoActivityRow(event: event)
                        }
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .runnerPage()
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
        HStack(alignment: .top, spacing: Runner.Spacing.tight) {
            Image(systemName: TodoActivityLogCopy.systemImage(for: event))
                .font(Runner.Typography.icon)
                .foregroundStyle(TodoActivityLogCopy.tint(for: event))
                .frame(width: Runner.Spacing.large)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Runner.Spacing.xsmall) {
                Text(TodoActivityLogCopy.eventTitle(for: event))
                    .font(Runner.Typography.bodyMedium)
                    .foregroundStyle(Runner.Palette.foreground)

                Text(TodoActivityLogCopy.todoTitle(for: event))
                    .font(Runner.Typography.small)
                    .foregroundStyle(Runner.Palette.foreground80)
                    .lineLimit(2)

                HStack(spacing: Runner.Spacing.small) {
                    Label(
                        TodoActivityLogCopy.actorText(for: event),
                        systemImage: TodoActivityLogCopy.actorSystemImage(for: event)
                    )

                    Text(AppFormatters.relativeString(for: event.occurredAt))
                }
                .font(Runner.Typography.caption)
                .foregroundStyle(Runner.Palette.mutedForeground)
                .lineLimit(1)
            }
        }
        .padding(.vertical, Runner.Spacing.xsmall)
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
            Runner.Palette.info
        case "marked_done":
            Runner.Palette.success
        case "deleted":
            Runner.Palette.destructive
        default:
            Runner.Palette.mutedForeground
        }
    }
}
