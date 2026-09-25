/// Presents quick capture as a native, nonmodal panel over its own window.
/// Closing an older capture can never dismiss a newer capture in flight.
import AppKit
import SwiftUI

struct QuickTodoPresenter: NSViewRepresentable {
    @Binding var isPresented: Bool
    let store: TodosStore
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSView { NSView() }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ view: NSView, context: Context) {
        if isPresented, let parent = view.window {
            context.coordinator.present(over: parent, store: store,
                colorScheme: colorScheme, isPresented: $isPresented)
        } else if !isPresented {
            context.coordinator.dismiss()
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.dismiss()
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private var panel: CapturePanel?
        private var presentationID: UUID?
        private var isPresented: Binding<Bool>?

        func present(over parent: NSWindow, store: TodosStore,
                     colorScheme: ColorScheme, isPresented: Binding<Bool>) {
            guard panel == nil else { return }
            self.isPresented = isPresented
            let id = UUID()
            presentationID = id
            let content = QuickTodoView(store: store) { [weak self] in
                guard self?.presentationID == id else { return }
                self?.dismiss()
            }
            .environment(\.colorScheme, colorScheme)

            let hosting = NSHostingView(rootView: content)
            let panel = CapturePanel(contentRect: .zero,
                styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            panel.title = "Quick Add Todo"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = true
            panel.animationBehavior = .utilityWindow
            panel.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
            panel.contentView = hosting
            panel.setContentSize(hosting.fittingSize)
            panel.delegate = self
            self.panel = panel

            // Keep the list visible and undimmed, with capture near its top.
            let frame = parent.frame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.maxY - frame.height / 4 - panel.frame.height / 2
            ))
            parent.addChildWindow(panel, ordered: .above)
            panel.makeKeyAndOrderFront(nil)
        }

        func dismiss() {
            guard let panel else { return }
            self.panel = nil
            presentationID = nil
            panel.delegate = nil
            panel.parent?.removeChildWindow(panel)
            panel.close()
            let binding = isPresented
            isPresented = nil
            // A representable update may initiate teardown.
            Task { @MainActor in binding?.wrappedValue = false }
        }

        func windowDidResignKey(_ notification: Notification) { dismiss() }
        func windowWillClose(_ notification: Notification) { dismiss() }
    }

    private final class CapturePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
}
