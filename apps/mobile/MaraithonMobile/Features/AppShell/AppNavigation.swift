import Foundation
import Observation

@MainActor
@Observable
final class AppNavigation {
    var selectedTab: AppTab = .today
    var requestedTodoFilter: TodoFilter?
    var requestedPeopleFilter: CRMStatusFilter?
    var requestedChatPrompt: String?
    var requestedChatThreadID: String?

    /// Hosts this app treats as navigation destinations. Anything else on the
    /// `maraithon://` scheme (e.g. magic sign-in links) is not navigation.
    private nonisolated static let navigationHosts: Set<String> = [
        "today", "todos", "stream", "people", "crm", "chat",
    ]

    nonisolated static func isNavigationURL(_ url: URL) -> Bool {
        url.scheme == "maraithon" && navigationHosts.contains(url.host ?? "")
    }

    /// Routes a `maraithon://<destination>` deep link (push notification taps,
    /// email links) to the matching tab.
    func route(_ url: URL) {
        guard Self.isNavigationURL(url) else { return }

        switch url.host {
        case "today":
            selectedTab = .today
        case "todos":
            selectedTab = .todos
        case "stream":
            selectedTab = .stream
        case "people", "crm":
            selectedTab = .crm
        case "chat":
            requestedChatThreadID = url.pathComponents.count > 1 ? url.lastPathComponent : nil
            selectedTab = .chat
        default:
            break
        }
    }

    func showTodos(_ filter: TodoFilter) {
        requestedTodoFilter = filter
        selectedTab = .todos
    }

    func showPeople(_ filter: CRMStatusFilter) {
        requestedPeopleFilter = filter
        selectedTab = .crm
    }

    func showChat(prompt: String? = nil) {
        requestedChatPrompt = prompt
        selectedTab = .chat
    }
}
