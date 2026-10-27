/// Keeps the visible task list current. SwiftUI cancels polling when the
/// window loses focus or the user opens a workspace or task creation sheet.
import SwiftUI

struct TodosAutoRefresh: ViewModifier {
    let store: TodosStore
    let isEnabled: Bool
    @Environment(\.scenePhase) private var scenePhase

    private var isActive: Bool { isEnabled && scenePhase == .active }

    func body(content: Content) -> some View {
        content.task(id: isActive) {
            guard isActive else { return }
            while !Task.isCancelled {
                await store.load(automatically: true)
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
            }
        }
    }
}
