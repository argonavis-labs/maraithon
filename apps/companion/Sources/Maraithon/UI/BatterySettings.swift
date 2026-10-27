import Foundation
import Observation
#if canImport(AppKit)
import AppKit
#endif

/// Owns the user-facing "Pause syncing when on battery" preference and
/// applies it when the system toggles into Low Power Mode.
///
/// Architecture:
/// - The toggle is persisted in `UserDefaults` so the preference survives
///   app restarts.
/// - The class observes `Process.didChangeLowPowerModeNotification` and
///   toggles every registered source via `SourceRegistry.pauseAll()` /
///   `startAll()` when the flag is on.
/// - The class is instantiated once at app scope (by `RootWindow`) and
///   bound to the live `SourceRegistry`. `SettingsView` only reads + writes
///   the toggle through this object — it doesn't own the lifecycle.
///
/// Invariants:
/// - Bind is idempotent. Calling `bind(sources:)` a second time replaces
///   the reference but doesn't double-register the observer.
/// - When the toggle is off, the observer becomes a no-op — but stays
///   subscribed so flipping back on doesn't require re-binding.
/// - The class never pauses the registry on its own — every pause flows
///   from a Low Power Mode transition while the toggle is on, or from the
///   "Apply now" path executed when the toggle is flipped on while the
///   Mac is already in Low Power Mode.
@Observable
@MainActor
final class BatterySettings {
    /// Shared instance owned by the app. `RootWindow` calls `bind(...)`
    /// once on appear so the settings pane can mutate it without holding
    /// the live `SourceRegistry`.
    static let shared = BatterySettings()

    /// UserDefaults key for the persisted toggle.
    static let pauseOnBatteryDefaultsKey = "com.maraithon.companion.pause_on_battery"

    private let defaults: UserDefaults
    private var sources: SourceRegistry?
    private var eventLog: EventLog?
    private var observation: NSObjectProtocol?
    private var isPausedByBattery: Bool = false

    /// Pluggable accessor for `ProcessInfo.isLowPowerModeEnabled` so tests
    /// can drive the state machine without flipping the OS.
    private var lowPowerModeProbe: @MainActor () -> Bool

    init(
        defaults: UserDefaults = .standard,
        lowPowerModeProbe: @escaping @MainActor () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
    ) {
        self.defaults = defaults
        self.lowPowerModeProbe = lowPowerModeProbe
    }

    /// Manually tear down the OS observer. Tests call this between
    /// runs so the shared singleton doesn't leak subscribers. Production
    /// callers never need to — the singleton lives for the app's
    /// lifetime.
    func teardown() {
        if let observation {
            NotificationCenter.default.removeObserver(observation)
        }
        observation = nil
    }

    /// User-facing toggle. Setting this to `true` while the Mac is already
    /// in Low Power Mode immediately pauses sources; setting it to `false`
    /// resumes any sources we paused.
    var pauseOnBattery: Bool {
        get { defaults.bool(forKey: Self.pauseOnBatteryDefaultsKey) }
        set {
            defaults.set(newValue, forKey: Self.pauseOnBatteryDefaultsKey)
            eventLog?.info(
                "battery_settings.pause_on_battery_changed",
                source: .ui,
                payload: ["enabled": String(newValue)]
            )
            applyCurrentState()
        }
    }

    /// Bind the settings to the live registry. Safe to call repeatedly —
    /// the second call simply replaces the reference. Registers the
    /// `NSProcessInfoPowerStateDidChange` observer the first time.
    func bind(sources: SourceRegistry, eventLog: EventLog) {
        self.sources = sources
        self.eventLog = eventLog
        if observation == nil {
            #if canImport(AppKit)
            observation = NotificationCenter.default.addObserver(
                forName: .NSProcessInfoPowerStateDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.applyCurrentState()
                }
            }
            #endif
        }
        applyCurrentState()
    }

    /// Re-evaluate the current Low Power Mode state and apply the
    /// matching action. Exposed so tests can drive the flow without an
    /// actual `NSProcessInfo` notification.
    func applyCurrentState() {
        guard let sources else { return }
        let lowPower = lowPowerModeProbe()
        let shouldPause = pauseOnBattery && lowPower

        if shouldPause && !isPausedByBattery {
            isPausedByBattery = true
            eventLog?.info("battery_settings.pausing_for_low_power", source: .ui)
            sources.pauseAll()
        } else if !shouldPause && isPausedByBattery {
            isPausedByBattery = false
            eventLog?.info("battery_settings.resuming_after_low_power", source: .ui)
            sources.startAll()
        }
    }

    /// Test seam: replace the probe so tests can simulate Low Power Mode
    /// transitions without touching the OS.
    func _setLowPowerModeProbe(_ probe: @escaping @MainActor () -> Bool) {
        self.lowPowerModeProbe = probe
    }
}
