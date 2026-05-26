import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// `MenuBarExtra` scene — the canonical 2026 SwiftUI API for menubar
/// items. Replaces the older `NSStatusItem`-based controller. The icon
/// reflects the live source registry state so the user can tell at a
/// glance whether sync is healthy without opening the window.
struct MaraithonMenuBar: Scene {
    @Environment(AppEnvironment.self) private var env

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(env)
        } label: {
            MenuBarLabel()
                .environment(env)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Menubar label with a rotating sync glyph when any source is actively
/// syncing. macOS 15+ uses `.symbolEffect(.rotate)`; older fallbacks rely
/// on a SwiftUI `.rotationEffect` driven by a timeline.
private struct MenuBarLabel: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let symbol = Image(systemName: env.menuBarSymbol)
            .accessibilityLabel(env.menuBarAccessibilityLabel)

        if env.isAnySourceSyncing, !reduceMotion {
            if #available(macOS 15.0, *) {
                symbol.symbolEffect(.rotate, options: .repeat(.continuous))
            } else {
                symbol.symbolEffect(.pulse, options: .repeating)
            }
        } else {
            symbol
        }
    }
}

private struct MenuBarContent: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if case .signedIn(let account) = env.deviceAuth.state {
            Text(account.email)
            Divider()
        }

        Button("Sync Now") {
            env.syncNowFromMenu()
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(!env.canSyncNow)

        Button(env.isPaused ? "Resume Sync" : "Pause Sync") {
            env.togglePaused()
        }

        Divider()

        Button("Show Window") {
            #if canImport(AppKit)
            NSApp.activate(ignoringOtherApps: true)
            #endif
            openWindow(id: "main")
        }

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",", modifiers: .command)

        CheckForUpdatesView(updates: env.updates)

        Divider()

        Button("Quit Maraithon") {
            #if canImport(AppKit)
            NSApp.terminate(nil)
            #endif
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
