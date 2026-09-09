/// People loads the independent projection only while this tab is visible.
import SwiftData
import SwiftUI
import PeopleNetworkKit

struct CRMView: View {
    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @State private var managing = false
    @State private var selectedTodo: TodoItem?
    @State private var selectedContact: CRMContact?

    var body: some View {
        NavigationStack {
            if let token = sessionStore.user?.sessionToken {
                PeopleNetworkExplorer(
                    loadNetwork: { days, query, focus in
                        try await MobileAPIClient().peopleNetwork(sessionToken: token, days: days, query: query, focus: focus)
                    },
                    loadPerson: { days, id in
                        try await MobileAPIClient().networkPerson(sessionToken: token, days: days, id: id)
                    },
                    openTodo: showTodo,
                    managePerson: showPerson
                )
                .id(sessionStore.user?.id)
            }
        }
        .sheet(isPresented: $managing) {
            CRMManageView()
        }
        .sheet(item: $selectedContact) { contact in
            NavigationStack { ContactDetailView(contact: contact) }
        }
        .sheet(item: $selectedTodo) { todo in
            NavigationStack { TodoDetailView(todo: todo) }
        }
    }

    private func showPerson(_ id: String?) {
        if let id, let uuid = UUID(uuidString: id),
           let contact = try? modelContext.fetch(FetchDescriptor<CRMContact>(predicate: #Predicate { $0.id == uuid })).first {
            selectedContact = contact
        } else { managing = true }
    }

    private func showTodo(_ id: String) {
        if let uuid = UUID(uuidString: id),
           let todo = try? modelContext.fetch(FetchDescriptor<TodoItem>(predicate: #Predicate { $0.id == uuid })).first {
            selectedTodo = todo
        } else if let url = URL(string: "https://maraithon.com/todos/\(id)") {
            openURL(url)
        }
    }
}
