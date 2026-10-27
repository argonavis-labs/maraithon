import SwiftUI

/// Focused action bridge that makes unmodified Gmail-style commands active
/// only while the Todo surface owns the scene.
struct TodoShortcutActions {
    var isTriage = false
    let perform: (TodoShortcut) -> Void

    struct Key: FocusedValueKey {
        typealias Value = TodoShortcutActions
    }

    struct QuickAddKey: FocusedValueKey {
        typealias Value = () -> Void
    }
}

extension FocusedValues {
    var quickTodoAction: (() -> Void)? {
        get { self[TodoShortcutActions.QuickAddKey.self] }
        set { self[TodoShortcutActions.QuickAddKey.self] = newValue }
    }

    var todoShortcutActions: TodoShortcutActions? {
        get { self[TodoShortcutActions.Key.self] }
        set { self[TodoShortcutActions.Key.self] = newValue }
    }
}
