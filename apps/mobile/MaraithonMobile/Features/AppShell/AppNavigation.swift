import Observation

@MainActor
@Observable
final class AppNavigation {
    var selectedTab: AppTab = .today
    var requestedTodoFilter: TodoFilter?
    var requestedPeopleFilter: CRMStatusFilter?
    var requestedChatPrompt: String?

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
