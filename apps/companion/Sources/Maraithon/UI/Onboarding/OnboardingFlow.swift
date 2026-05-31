import Foundation
import Observation

/// State machine for the first-run onboarding sequence:
/// **Connect → What we sync → Full Disk Access → Backfill setup → Done.**
///
/// The flow is owned by `AppEnvironment` and rendered by `OnboardingView`.
/// It persists a single boolean — "onboarding complete" — to
/// `UserDefaults` so a user who finishes onboarding once never sees it
/// again, even after signing out and back in.
///
/// Invariants:
///   - `current` only moves forward through `advance()` (no skipping).
///   - `back()` is bounded by the start of the flow.
///   - `reset()` returns `current` to `.connect` without clearing the
///     "complete" flag (used when the user signs out mid-flow before
///     ever finishing).
///   - `markComplete()` flips the persisted flag; the caller still must
///     call `advance()` to move into the `.done` state.
///   - `markFullDiskAccessSkipped()` flips a separate persisted flag that
///     `RootWindow` reads to render the "FDA required" banner over the
///     main UI. The flag survives quit-and-relaunch so the banner sticks
///     until the user actually grants access.
@Observable
@MainActor
final class OnboardingFlow {
    /// Ordered onboarding steps. `.done` is a terminal state — the host
    /// view should swap in the main split view once it's reached.
    enum Step: String, CaseIterable, Hashable, Sendable {
        case connect
        case whatWeSync
        case fullDiskAccess
        case backfill
        case done

        /// Steps that participate in the progress indicator. `.done` is
        /// terminal and isn't shown.
        static let progressSteps: [Step] = [.connect, .whatWeSync, .fullDiskAccess, .backfill]
    }

    /// UserDefaults key for the persisted "onboarding complete" flag.
    static let completedDefaultsKey = "com.maraithon.companion.onboarding_complete"
    /// Tracks the last step the user was on so the flow can resume after
    /// the app was killed mid-onboarding (e.g., macOS quitting it when
    /// the user grants Full Disk Access).
    static let currentStepDefaultsKey = "com.maraithon.companion.onboarding_step"
    /// Flag flipped by `markFullDiskAccessSkipped()`. Read by `RootWindow`
    /// to decide whether to render the "FDA required" banner.
    static let fullDiskAccessSkippedDefaultsKey = "com.maraithon.companion.fda_skipped"

    private(set) var current: Step
    private(set) var fullDiskAccessSkipped: Bool
    private let defaults: UserDefaults
    private let eventLog: EventLog?

    init(
        defaults: UserDefaults = .standard,
        eventLog: EventLog? = nil
    ) {
        self.defaults = defaults
        self.eventLog = eventLog
        self.fullDiskAccessSkipped = defaults.bool(forKey: Self.fullDiskAccessSkippedDefaultsKey)

        if defaults.bool(forKey: Self.completedDefaultsKey) {
            self.current = .done
        } else if let raw = defaults.string(forKey: Self.currentStepDefaultsKey),
                  let step = Step(rawValue: raw) {
            self.current = step
        } else {
            self.current = .connect
        }
    }

    /// True when the user has previously completed onboarding. Persisted
    /// so signing out + back in does not replay the flow.
    var isComplete: Bool {
        defaults.bool(forKey: Self.completedDefaultsKey)
    }

    /// True when the user pressed "I'll do this later" on the FDA screen.
    /// `RootWindow` reads this to render the persistent banner above the
    /// main split view.
    var isFullDiskAccessSkipped: Bool {
        fullDiskAccessSkipped
    }

    /// Progress through the visible (non-terminal) steps, in [0, 1]. Used
    /// to drive the `ProgressView` at the top of `OnboardingView`.
    var progress: Double {
        let total = Step.progressSteps.count
        guard total > 0 else { return 0 }
        switch current {
        case .connect: return 0.0
        case .whatWeSync: return Double(1) / Double(total)
        case .fullDiskAccess: return Double(2) / Double(total)
        case .backfill: return Double(3) / Double(total)
        case .done: return 1.0
        }
    }

    /// Advance to the next step in the flow. Calling `advance()` while in
    /// `.done` is a no-op.
    func advance() {
        let from = current
        switch current {
        case .connect: current = .whatWeSync
        case .whatWeSync: current = .fullDiskAccess
        case .fullDiskAccess: current = .backfill
        case .backfill: current = .done
        case .done: return
        }
        defaults.set(current.rawValue, forKey: Self.currentStepDefaultsKey)
        eventLog?.info(
            "onboarding.advance",
            source: .ui,
            payload: ["from": from.rawValue, "to": current.rawValue]
        )
    }

    /// Step backwards. Bounded by `.connect`; calling `back()` while on
    /// the first step is a no-op.
    func back() {
        let from = current
        switch current {
        case .connect: return
        case .whatWeSync: current = .connect
        case .fullDiskAccess: current = .whatWeSync
        case .backfill: current = .fullDiskAccess
        case .done: current = .backfill
        }
        eventLog?.info(
            "onboarding.back",
            source: .ui,
            payload: ["from": from.rawValue, "to": current.rawValue]
        )
    }

    /// Reset to the first step. Does NOT clear the "complete" flag —
    /// users who already finished onboarding don't get re-prompted.
    /// Called when the user signs out before completing the flow.
    func reset() {
        guard !isComplete else { return }
        if current != .connect {
            eventLog?.info(
                "onboarding.reset",
                source: .ui,
                payload: ["from": current.rawValue]
            )
        }
        current = .connect
    }

    /// Persist that the user has finished onboarding. Idempotent — safe
    /// to call multiple times. Caller still calls `advance()` to move
    /// the state into `.done`.
    func markComplete() {
        guard !isComplete else { return }
        defaults.set(true, forKey: Self.completedDefaultsKey)
        eventLog?.info("onboarding.completed", source: .ui)
    }

    /// Persist that the user opted to skip Full Disk Access during
    /// onboarding. Idempotent. The flag is independent of `markComplete`
    /// — a user can skip FDA, finish onboarding, and still see the
    /// banner asking them to grant access later.
    func markFullDiskAccessSkipped() {
        guard !isFullDiskAccessSkipped else { return }
        fullDiskAccessSkipped = true
        defaults.set(true, forKey: Self.fullDiskAccessSkippedDefaultsKey)
        eventLog?.warning("onboarding.full_disk_access.skipped", source: .ui)
    }

    /// Clear the FDA-skipped flag. Called once the indicator detects
    /// access is granted so the banner disappears without a restart.
    func clearFullDiskAccessSkipped() {
        guard isFullDiskAccessSkipped else { return }
        fullDiskAccessSkipped = false
        defaults.set(false, forKey: Self.fullDiskAccessSkippedDefaultsKey)
        eventLog?.info("onboarding.full_disk_access.skip_cleared", source: .ui)
    }

    /// Record that the running app can read the protected Messages
    /// database. This is used outside first-run onboarding so a user who
    /// grants Full Disk Access later does not keep seeing the skipped-FDA
    /// banner after a relaunch.
    func recordFullDiskAccessGranted() {
        clearFullDiskAccessSkipped()
    }
}
