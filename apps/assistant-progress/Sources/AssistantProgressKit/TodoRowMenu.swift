/// Native Mac secondary-click handling spans the whole row, including nested
/// SwiftUI buttons. Primary clicks pass through unchanged.
#if os(macOS)
import AppKit
import SwiftUI

public struct TodoRowMenu: NSViewRepresentable {
    let primaryTitle: String
    let primaryEnabled: Bool
    let ignoreEnabled: Bool
    let primary: () -> Void
    let ignore: () -> Void
    let scrollChanged: ((CGFloat) -> Void)?
    let scrollEnded: ((Bool) -> Void)?

    public init(primaryTitle: String, primaryEnabled: Bool, ignoreEnabled: Bool,
                primary: @escaping () -> Void, ignore: @escaping () -> Void,
                scrollChanged: ((CGFloat) -> Void)? = nil, scrollEnded: ((Bool) -> Void)? = nil) {
        self.primaryTitle = primaryTitle
        self.primaryEnabled = primaryEnabled
        self.ignoreEnabled = ignoreEnabled
        self.primary = primary
        self.ignore = ignore
        self.scrollChanged = scrollChanged
        self.scrollEnded = scrollEnded
    }

    public func makeNSView(context: Context) -> MenuView { MenuView() }
    public func updateNSView(_ view: MenuView, context: Context) {
        view.actions = self
    }

    public final class MenuView: NSView {
        var actions: TodoRowMenu?
        private var scrolling = false

        public override func hitTest(_ point: NSPoint) -> NSView? {
            guard super.hitTest(point) != nil, let event = NSApp.currentEvent else { return nil }
            if event.type == .rightMouseDown ||
                (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) { return self }
            if event.type == .scrollWheel, event.hasPreciseScrollingDeltas,
               !event.phase.isEmpty, actions?.scrollChanged != nil,
               scrolling || abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) { return self }
            return nil
        }

        public override func rightMouseDown(with event: NSEvent) { showMenu(event) }
        public override func mouseDown(with event: NSEvent) { showMenu(event) }

        private func showMenu(_ event: NSEvent) {
            guard let actions else { return }
            let menu = NSMenu()
            menu.autoenablesItems = false
            let add = NSMenuItem(title: actions.primaryTitle, action: #selector(runPrimary), keyEquivalent: "")
            add.target = self
            add.isEnabled = actions.primaryEnabled
            menu.addItem(add)
            let ignore = NSMenuItem(title: "Ignore", action: #selector(runIgnore), keyEquivalent: "")
            ignore.target = self
            ignore.isEnabled = actions.ignoreEnabled
            menu.addItem(ignore)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        public override func scrollWheel(with event: NSEvent) {
            guard event.momentumPhase.isEmpty else { return }
            if event.phase.contains(.cancelled) || event.phase.contains(.ended) {
                actions?.scrollEnded?(event.phase.contains(.cancelled))
                scrolling = false
            } else {
                scrolling = true
                actions?.scrollChanged?(event.scrollingDeltaX)
            }
        }

        @objc private func runPrimary() { if actions?.primaryEnabled == true { actions?.primary() } }
        @objc private func runIgnore() { if actions?.ignoreEnabled == true { actions?.ignore() } }
    }
}
#endif
