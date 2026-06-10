import SwiftUI

enum AppTab: Hashable {
    case today
    case todos
    case stream
    case crm
    case chat
}

struct AppShellView: View {
    @State private var navigation = AppNavigation()

    var body: some View {
        TabView(selection: Binding(
            get: { navigation.selectedTab },
            set: { navigation.selectedTab = $0 }
        )) {
            Tab("Today", systemImage: "sparkles.rectangle.stack", value: .today) {
                TodayView()
            }

            Tab("Work", systemImage: "checklist", value: .todos) {
                TodosView()
            }

            Tab("Stream", systemImage: "wave.3.right", value: .stream) {
                StreamView()
            }

            Tab("People", systemImage: "person.2.crop.square.stack", value: .crm) {
                CRMView()
            }

            Tab("Chat", systemImage: "bubble.left.and.bubble.right", value: .chat) {
                ChatThreadsView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .environment(navigation)
    }
}
