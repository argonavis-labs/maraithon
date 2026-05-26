// UpdateController.swift
//
// Sparkle 2.x wrapper for the Maraithon companion. Exposes a small
// `@Observable` surface so SwiftUI views can bind to "automatic check"
// state, surface the last-check timestamp, and trigger a manual check.
//
// Invariant: this type is the single owner of the `SPUStandardUpdaterController`
// instance. Every Sparkle state change is mirrored into `EventLog` under
// the `system` source with an `updates.*` prefix so the rest of the app
// (and Console.app) can observe the update lifecycle without depending on
// Sparkle directly.
//
// `swift build` does not have Sparkle available — it lives only in the
// Xcode project because it must embed a framework bundle. We compile a
// no-op stub under `#if !canImport(Sparkle)` so SwiftPM builds stay clean
// and tests can still exercise the `@Observable` surface.

import Foundation
import Observation
#if canImport(Sparkle)
import Sparkle
#endif

/// Wrapper around `SPUStandardUpdaterController` exposing the bits SwiftUI
/// views need: a binding-friendly `automaticallyChecksForUpdates`, the
/// `lastUpdateCheckDate`, and a `checkForUpdates()` method. The underlying
/// controller is held strongly so KVO/observation stays alive for the
/// app's lifetime.
///
/// Lifecycle events are emitted to `EventLog`:
/// - `updates.check_started`
/// - `updates.check_finished`
/// - `updates.update_found`
/// - `updates.update_installed_on_next_launch`
@Observable
@MainActor
final class UpdateController {
    /// Mirrors `SPUUpdater.automaticallyChecksForUpdates`. Setting this
    /// propagates into Sparkle and emits an `updates.auto_check.changed`
    /// log entry. Sparkle persists the value in `NSUserDefaults` under its
    /// own key, so the next launch will pick it up.
    var automaticallyChecksForUpdates: Bool {
        get { _automaticallyChecksForUpdates }
        set {
            guard _automaticallyChecksForUpdates != newValue else { return }
            _automaticallyChecksForUpdates = newValue
            #if canImport(Sparkle)
            controller?.updater.automaticallyChecksForUpdates = newValue
            #endif
            eventLog?.info(
                "updates.auto_check.changed",
                source: .system,
                payload: ["enabled": String(newValue)]
            )
        }
    }

    /// Last time Sparkle completed a check (success or otherwise). `nil`
    /// before the first run.
    private(set) var lastUpdateCheckDate: Date?

    /// `true` while a check is in flight. UI may use this to dim the
    /// "Check Now" button — Sparkle's own `canCheckForUpdates` flag covers
    /// the deeper "is the updater configured" check.
    private(set) var isChecking: Bool = false

    /// Whether the underlying `SPUUpdater` is in a state that accepts a
    /// manual check. Pre-Sparkle-startup or during an in-flight check this
    /// is `false`. In SwiftPM builds (no Sparkle) it returns `false` and
    /// the menu items disable themselves.
    var canCheckForUpdates: Bool {
        #if canImport(Sparkle)
        return controller?.updater.canCheckForUpdates ?? false
        #else
        return false
        #endif
    }

    /// Whether Sparkle is actually wired in. SwiftUI views can switch
    /// labels / hide rows based on this rather than guarding on `#if`.
    var isSparkleEnabled: Bool {
        #if canImport(Sparkle)
        return controller != nil
        #else
        return false
        #endif
    }

    #if canImport(Sparkle)
    /// The standard controller wraps an `SPUUpdater`, a
    /// `SPUStandardUserDriver`, starts the updater for us, and exposes
    /// `checkForUpdates(_:)` as the action for the menu item view.
    let controller: SPUStandardUpdaterController?

    /// Convenience for the SwiftUI `CheckForUpdatesView` helper, which
    /// needs the underlying updater to validate its button. In SwiftPM
    /// builds the helper view is omitted, so this property is gated too.
    var updater: SPUUpdater? { controller?.updater }
    #else
    let controller: AnyObject? = nil
    var updater: AnyObject? { nil }
    #endif

    private var _automaticallyChecksForUpdates: Bool
    private weak var eventLog: EventLog?

    #if canImport(Sparkle)
    private let updaterDelegate: UpdaterDelegate
    private let userDriverDelegate: UserDriverDelegate
    #endif

    init(eventLog: EventLog? = nil) {
        self.eventLog = eventLog

        #if canImport(Sparkle)
        // Sparkle is permanently disabled in this build — it was firing
        // an "Unable to Check For Updates" alert on every launch (the
        // dev build can't fetch the signed appcast) and blocking the
        // main window until dismissed. Re-enable by re-introducing
        // `SPUStandardUpdaterController(startingUpdater: true, ...)`.
        let updaterDelegate = UpdaterDelegate(eventLog: eventLog)
        let userDriverDelegate = UserDriverDelegate()
        self.updaterDelegate = updaterDelegate
        self.userDriverDelegate = userDriverDelegate
        self.controller = nil
        self._automaticallyChecksForUpdates = false
        self.lastUpdateCheckDate = nil
        eventLog?.info(
            "updates.controller_disabled",
            source: .system,
            payload: ["reason": "dev_build_appcast_unsigned"]
        )
        #else
        self._automaticallyChecksForUpdates = false
        eventLog?.info(
            "updates.controller_started",
            source: .system,
            payload: ["sparkle": "unavailable"]
        )
        #endif
    }

    /// Triggers a manual update check. Surfaces the standard Sparkle UI
    /// (progress sheet, "no updates available" alert, etc.). Safe to call
    /// when Sparkle is absent — logs a warning and returns.
    func checkForUpdates() {
        #if canImport(Sparkle)
        guard let controller else {
            eventLog?.warning(
                "updates.check_skipped",
                source: .system,
                payload: ["reason": "sparkle_disabled"]
            )
            return
        }
        isChecking = true
        eventLog?.info("updates.check_started", source: .system)
        controller.updater.checkForUpdates()
        // Sparkle drives the rest of the lifecycle. The delegate marks
        // `isChecking = false` on completion and refreshes the timestamp.
        #else
        eventLog?.warning(
            "updates.check_skipped",
            source: .system,
            payload: ["reason": "sparkle_unavailable"]
        )
        #endif
    }

    fileprivate func didFinishCheck(foundUpdate: Bool, error: Error?) {
        isChecking = false
        #if canImport(Sparkle)
        lastUpdateCheckDate = controller?.updater.lastUpdateCheckDate ?? lastUpdateCheckDate
        #endif
        var payload: [String: String] = ["found": String(foundUpdate)]
        if let error {
            payload["error"] = String(describing: error)
            eventLog?.warning("updates.check_finished", source: .system, payload: payload)
        } else {
            eventLog?.info("updates.check_finished", source: .system, payload: payload)
        }
    }

    fileprivate func didFindUpdate(version: String?) {
        var payload: [String: String] = [:]
        if let version { payload["version"] = version }
        eventLog?.info("updates.update_found", source: .system, payload: payload)
    }

    fileprivate func willInstallOnNextLaunch(version: String?) {
        var payload: [String: String] = [:]
        if let version { payload["version"] = version }
        eventLog?.info(
            "updates.update_installed_on_next_launch",
            source: .system,
            payload: payload
        )
    }
}

#if canImport(Sparkle)
/// Sparkle delegate that translates lifecycle callbacks into `EventLog`
/// entries and back into `UpdateController` state. Held strongly by
/// `UpdateController`; Sparkle only keeps a weak reference.
///
/// `SPUUpdaterDelegate` is `NS_SWIFT_UI_ACTOR`, so the methods inherit
/// `@MainActor` isolation — that aligns with our `UpdateController`
/// `@MainActor` annotation and avoids needing any cross-actor hops.
@MainActor
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    weak var owner: UpdateController?
    private weak var eventLog: EventLog?

    init(eventLog: EventLog?) {
        self.eventLog = eventLog
    }

    func updater(
        _ updater: SPUUpdater,
        didFindValidUpdate item: SUAppcastItem
    ) {
        owner?.didFindUpdate(version: item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        owner?.didFinishCheck(foundUpdate: false, error: nil)
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        owner?.didFinishCheck(foundUpdate: false, error: error)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        owner?.willInstallOnNextLaunch(version: item.displayVersionString)
    }
}

/// Standard user-driver delegate placeholder. Kept separate so we can
/// hook gentle-reminder / status-item behaviors in later without touching
/// the updater delegate.
@MainActor
private final class UserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {}
#endif
