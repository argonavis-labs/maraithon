import Foundation
import Observation

/// Shared service container injected through the SwiftUI environment.
/// Owns the long-lived services that views, sources, and the sync engine
/// all need access to.
///
/// Construction order matters here:
///   1. `EventLog` first — every other service emits to it.
///   2. `Blocklist` — used by sources to filter before push.
///   3. `DeviceAuth` — owns the bearer token; everyone reads from it.
///   4. `SyncEngine` — needs both `EventLog` and `DeviceAuth`.
///   5. `SourceRegistry` — installs sources whose outboxes call into
///      `SyncEngine`.
@Observable
@MainActor
final class AppEnvironment {
    let eventLog: EventLog
    let deviceAuth: DeviceAuth
    let onboarding: OnboardingFlow
    let syncEngine: SyncEngine
    let sources: SourceRegistry
    let blocklist: Blocklist
    /// Sparkle wrapper. Built here so views can read it through the
    /// `AppEnvironment` rather than threading a separate `@State` through
    /// the scene graph — keeps `MaraithonApp` a single owner of services.
    let updates: UpdateController
    /// Realtime WebSocket channel for instant sync. Each ingest helper
    /// receives a reference and prefers it over HTTP when connected.
    let realtime: RealtimeChannel

    private(set) var isPaused: Bool = false

    init() {
        let log = EventLog()
        self.eventLog = log
        self.blocklist = Blocklist()
        self.deviceAuth = DeviceAuth(eventLog: log)
        self.onboarding = OnboardingFlow(eventLog: log)
        let engine = SyncEngine(eventLog: log, deviceAuth: deviceAuth)
        self.syncEngine = engine
        let registry = SourceRegistry(eventLog: log)
        self.sources = registry
        self.updates = UpdateController(eventLog: log)

        let realtimeChannel = RealtimeChannel(
            deviceId: deviceAuth.deviceId,
            tokenProvider: { [weak deviceAuth] in
                await MainActor.run { [deviceAuth] in deviceAuth?.currentToken }
            },
            log: { @Sendable [weak log] msg, payload in
                Task { @MainActor in log?.info(msg, source: .realtime, payload: payload) }
            }
        )
        self.realtime = realtimeChannel

        let imessageIngest = IMessageIngest(
            tokenProvider: { [weak deviceAuth] in
                await MainActor.run { [deviceAuth] in deviceAuth?.currentToken }
            },
            realtime: realtimeChannel
        )
        let imessage = IMessageSource(
            blocklist: blocklist,
            eventLog: log,
            ingest: imessageIngest,
            deviceIdProvider: { [weak deviceAuth] in deviceAuth?.deviceId ?? UUID() }
        )
        registry.register(imessage)

        let notesIngest = NotesIngest(
            tokenProvider: { [weak deviceAuth] in
                await MainActor.run { [deviceAuth] in deviceAuth?.currentToken }
            },
            realtime: realtimeChannel
        )
        let notes = NotesSource(
            eventLog: log,
            ingest: notesIngest,
            deviceIdProvider: { [weak deviceAuth] in deviceAuth?.deviceId ?? UUID() }
        )
        registry.register(notes)

        let voiceMemosIngest = VoiceMemosIngest(
            tokenProvider: { [weak deviceAuth] in
                await MainActor.run { [deviceAuth] in deviceAuth?.currentToken }
            },
            realtime: realtimeChannel
        )
        let voiceMemos = VoiceMemosSource(
            eventLog: log,
            ingest: voiceMemosIngest,
            deviceIdProvider: { [weak deviceAuth] in deviceAuth?.deviceId ?? UUID() }
        )
        registry.register(voiceMemos)

        let remindersIngest = RemindersIngest(
            tokenProvider: { [weak deviceAuth] in
                await MainActor.run { [deviceAuth] in deviceAuth?.currentToken }
            },
            realtime: realtimeChannel
        )
        let reminders = RemindersSource(
            eventLog: log,
            ingest: remindersIngest,
            deviceIdProvider: { [weak deviceAuth] in deviceAuth?.deviceId ?? UUID() }
        )
        registry.register(reminders)

        let calendarIngest = CalendarIngest(
            tokenProvider: { [weak deviceAuth] in
                await MainActor.run { [deviceAuth] in deviceAuth?.currentToken }
            },
            realtime: realtimeChannel
        )
        let calendar = CalendarEventsSource(
            eventLog: log,
            ingest: calendarIngest,
            deviceIdProvider: { [weak deviceAuth] in deviceAuth?.deviceId ?? UUID() }
        )
        registry.register(calendar)

        let filesIngest = FilesIngest(
            tokenProvider: { [weak deviceAuth] in
                await MainActor.run { [deviceAuth] in deviceAuth?.currentToken }
            },
            realtime: realtimeChannel
        )
        let files = FilesSource(
            eventLog: log,
            ingest: filesIngest,
            deviceIdProvider: { [weak deviceAuth] in deviceAuth?.deviceId ?? UUID() }
        )
        registry.register(files)

        let browserHistoryIngest = BrowserHistoryIngest(
            tokenProvider: { [weak deviceAuth] in
                await MainActor.run { [deviceAuth] in deviceAuth?.currentToken }
            },
            realtime: realtimeChannel
        )
        let browserHistory = BrowserHistorySource(
            eventLog: log,
            ingest: browserHistoryIngest,
            deviceIdProvider: { [weak deviceAuth] in deviceAuth?.deviceId ?? UUID() }
        )
        registry.register(browserHistory)

        // Kick off the realtime channel. start() loops with backoff until a
        // valid token is available, so calling it pre-sign-in is safe.
        Task { [realtime = realtimeChannel] in
            await realtime.start()
        }

        // Auto-start every registered source so polling begins immediately
        // on launch. Sources that need permissions they don't yet have
        // surface as `.needsAttention(...)` rather than crashing.
        registry.startAll()
    }

    /// Routes inbound deep-link URLs (e.g. `maraithon://device-token/<t>`).
    func handleIncomingURL(_ url: URL) {
        deviceAuth.handleIncomingURL(url)
    }

    /// Triggered by the global `⌘R` shortcut and the toolbar.
    func syncNowFromMenu() {
        sources.syncNow()
    }

    /// Toggle every registered source between paused and running. Surfaces
    /// via the menubar so the user can mute syncing without quitting.
    func togglePaused() {
        if isPaused {
            sources.startAll()
            isPaused = false
            eventLog.info("app.resume", source: .system)
        } else {
            sources.pauseAll()
            isPaused = true
            eventLog.info("app.pause", source: .system)
        }
    }

    /// Sync Now is only meaningful once the user is paired and sync isn't
    /// already in flight or paused.
    var canSyncNow: Bool {
        switch deviceAuth.state {
        case .signedIn: return !isPaused
        default: return false
        }
    }

    /// SF Symbol for the menubar item. Reflects the highest-priority
    /// signal across registered sources so the user can read it at a
    /// glance.
    var menuBarSymbol: String {
        if isPaused { return "pause.circle" }
        switch deviceAuth.state {
        case .signedOut, .error:
            return "exclamationmark.triangle"
        default:
            break
        }
        let states = sources.sources.filter { !$0.comingSoon }.map(\.state)
        if states.contains(where: { if case .error = $0 { return true } else { return false } }) {
            return "exclamationmark.octagon.fill"
        }
        if states.contains(where: { if case .needsAttention = $0 { return true } else { return false } }) {
            return "exclamationmark.triangle.fill"
        }
        if states.contains(.syncing) { return "arrow.triangle.2.circlepath" }
        if states.contains(.connected) { return "checkmark.circle" }
        return "arrow.triangle.2.circlepath.circle"
    }

    /// True when any installed source is mid-sync. Used by the menubar
    /// label to drive the rotating glyph.
    var isAnySourceSyncing: Bool {
        sources.sources.contains { $0.state == .syncing }
    }

    /// Accessibility label paired with the menubar SF Symbol.
    var menuBarAccessibilityLabel: String {
        if isPaused { return "Maraithon — paused" }
        switch deviceAuth.state {
        case .signedOut: return "Maraithon — not connected"
        case .error: return "Maraithon — needs attention"
        case .connecting, .awaitingApproval: return "Maraithon — connecting"
        case .signedIn: return "Maraithon — syncing"
        }
    }
}
