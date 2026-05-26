// UpdateCommands.swift
//
// SwiftUI integration glue for `UpdateController`. Provides the canonical
// 2026 Sparkle SwiftUI pattern — a `CheckForUpdatesView` helper that
// observes the underlying `SPUUpdater` for `canCheckForUpdates`, so the
// menu item disables itself while a check is in flight, and a
// `CommandGroup` that slots it after the app-info ("About") item in the
// main menu.
//
// SwiftPM (no Sparkle) compiles a degraded variant that always shows the
// menu item disabled — preserves the menu layout for tests that exercise
// the app harness without a framework bundle to embed.

import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

/// A thin `View` that exposes Sparkle's "Check for Updates…" entry point.
/// Built to be dropped into a `CommandGroup` or any other `Menu`.
///
/// The view observes `SPUUpdater.canCheckForUpdates` via the
/// `@ObservedObject` adapter Sparkle's docs recommend, so the menu item
/// stays in sync with whether a check is in flight.
struct CheckForUpdatesView: View {
    let updates: UpdateController

    init(updates: UpdateController) {
        self.updates = updates
    }

    var body: some View {
        #if canImport(Sparkle)
        if let updater = updates.updater {
            CheckForUpdatesButton(updater: updater)
        } else {
            disabledFallback
        }
        #else
        disabledFallback
        #endif
    }

    private var disabledFallback: some View {
        // No Sparkle (SwiftPM build / previews) — show the menu item but
        // disable it so the menu layout stays consistent.
        Button("Check for Updates…") {}
            .disabled(true)
    }
}

#if canImport(Sparkle)
/// Observes `SPUUpdater`'s KVO-driven `canCheckForUpdates` flag so the
/// menu item enables/disables on its own as Sparkle's state changes.
/// This is the pattern Sparkle's "programmatic setup" docs recommend for
/// SwiftUI apps.
private struct CheckForUpdatesButton: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}

/// Tiny KVO adapter — `SPUUpdater.canCheckForUpdates` is KVO-observable,
/// so we mirror it into an `@ObservedObject` for SwiftUI to subscribe to.
@MainActor
private final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates: Bool

    private var observation: NSKeyValueObservation?

    init(updater: SPUUpdater) {
        self.canCheckForUpdates = updater.canCheckForUpdates
        self.observation = updater.observe(
            \.canCheckForUpdates,
            options: [.new]
        ) { [weak self] _, change in
            // KVO callbacks come back on whatever thread fired them.
            // Hop to main to keep `@Published` writes on the right actor.
            let newValue = change.newValue ?? false
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = newValue
            }
        }
    }

    deinit {
        observation?.invalidate()
    }
}
#endif

/// Top-level `Commands` group that slots the "Check for Updates…" item
/// just after the standard "About Maraithon" entry in the app menu. Drop
/// this into `MaraithonApp` once via `.commands { UpdateCommands(...) }`.
struct UpdateCommands: Commands {
    let updates: UpdateController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesView(updates: updates)
        }
    }
}
