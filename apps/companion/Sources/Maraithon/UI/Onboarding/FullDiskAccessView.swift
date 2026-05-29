import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Second onboarding step: walks the user to System Settings → Privacy &
/// Security → Full Disk Access. Polls every 2 seconds for `chat.db`
/// readability so the "Continue" button can light up the moment access is
/// granted (no manual refresh needed).
///
/// Owned by the UI team; the iMessage team is the source of truth for the
/// actual database path but this view performs only a `O_RDONLY` open
/// probe — no schema reads.
struct FullDiskAccessView: View {
    @Environment(AppEnvironment.self) private var env

    /// Called when the user dismisses the screen having confirmed access.
    var onContinue: () -> Void = {}

    /// Called when the user explicitly skips Full Disk Access during
    /// onboarding. Lets the host flag the persisted "skipped" state and
    /// jump past the backfill step (iMessage cannot be backfilled).
    var onSkip: () -> Void = {}

    /// Test seam for the readability probe. Production passes `nil` and
    /// uses `probeChatDBReadability`.
    var probe: (@MainActor () -> Bool)? = nil

    /// Test seam for the auto-advance delay so tests don't have to wait
    /// half a second.
    var autoAdvanceDelay: Duration = .milliseconds(500)

    @State private var hasAccess: Bool = false
    @State private var pollTask: Task<Void, Never>? = nil
    @State private var autoAdvanceTask: Task<Void, Never>? = nil
    @State private var didAutoAdvance: Bool = false

    var body: some View {
        VStack(spacing: Tokens.Spacing.large) {
            Spacer(minLength: 0)

            Image(systemName: "lock.shield")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: Tokens.IconSize.large, height: Tokens.IconSize.large)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: Tokens.Spacing.small) {
                Text(FullDiskAccessCopy.onboardingTitle)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(FullDiskAccessCopy.onboardingBody)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            statusIndicator

            if let installHint = FullDiskAccessInstallHint.currentMessage() {
                Label {
                    Text(installHint)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(StatusTone.attention.color)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 420, alignment: .leading)
                .accessibilityElement(children: .combine)
            }

            VStack(spacing: Tokens.Spacing.small) {
                Button {
                    openSystemSettings()
                } label: {
                    Label(FullDiskAccessCopy.openSettingsButton, systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)

                Button {
                    onContinue()
                } label: {
                    Text(FullDiskAccessCopy.continueButton)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .keyboardShortcut(.defaultAction)
                .disabled(!hasAccess)

                Button(FullDiskAccessCopy.skipButton) {
                    onSkip()
                }
                .controlSize(.large)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 320)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.Spacing.xlarge)
        .padding(.vertical, Tokens.Spacing.xlarge)
        .frame(maxWidth: Tokens.Layout.onboardingMaxWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.default, value: hasAccess)
        .onAppear { startPolling() }
        .onDisappear {
            stopPolling()
            autoAdvanceTask?.cancel()
            autoAdvanceTask = nil
        }
    }

    private var statusIndicator: some View {
        HStack(spacing: Tokens.Spacing.small) {
            Image(systemName: hasAccess ? "circle.fill" : "circle")
                .foregroundStyle(hasAccess ? StatusTone.good.color : StatusTone.muted.color)
            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusText)
    }

    /// Status copy mirrors the three observable substates: not yet,
    /// granted-but-still-here, and granted-with-auto-advance pending.
    /// The "Granted, continuing…" beat gives the user a half-second of
    /// confirmation before we jump to the backfill step.
    private var statusText: String {
        if hasAccess {
            return didAutoAdvance ? FullDiskAccessCopy.autoAdvanceStatus : FullDiskAccessCopy.grantedStatus
        }
        return FullDiskAccessCopy.waitingStatus
    }

    private func openSystemSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        guard let url = URL(string: urlString) else {
            env.eventLog.warning(
                "onboarding.full_disk_access.url_invalid",
                source: .ui,
                payload: ["url": urlString]
            )
            return
        }
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
        env.eventLog.info("onboarding.full_disk_access.open_settings", source: .ui)
    }

    private func startPolling() {
        stopPolling()
        let probeClosure: @MainActor () -> Bool = probe ?? { Self.probeChatDBReadability() }
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                let access = probeClosure()
                if access != hasAccess {
                    hasAccess = access
                    env.eventLog.info(
                        "onboarding.full_disk_access.status_changed",
                        source: .ui,
                        payload: ["granted": String(access)]
                    )
                    if access {
                        clearSkipFlagIfNeeded()
                        scheduleAutoAdvance()
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Granting FDA after a previous skip clears the skipped flag so the
    /// main-window banner disappears without a relaunch.
    private func clearSkipFlagIfNeeded() {
        env.onboarding.recordFullDiskAccessGranted()
    }

    /// Auto-advance after `autoAdvanceDelay` so the user gets a beat to
    /// read the "Granted, continuing…" confirmation. The task short-
    /// circuits if the view disappears (the user already pressed
    /// Continue) or if access disappears again.
    private func scheduleAutoAdvance() {
        guard !didAutoAdvance else { return }
        didAutoAdvance = true
        env.eventLog.info(
            "onboarding.full_disk_access.auto_advance_scheduled",
            source: .ui
        )
        autoAdvanceTask?.cancel()
        autoAdvanceTask = Task { @MainActor in
            try? await Task.sleep(for: autoAdvanceDelay)
            guard !Task.isCancelled, hasAccess else { return }
            onContinue()
        }
    }

    /// Attempts an `O_RDONLY` open on `~/Library/Messages/chat.db`. We don't
    /// keep the handle — the question is purely whether the OS lets us
    /// read it without permission errors.
    static func probeChatDBReadability() -> Bool {
        let fm = FileManager.default
        guard let home = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return false
        }
        let chatDB = home
            .appendingPathComponent("Messages", isDirectory: true)
            .appendingPathComponent("chat.db")
        guard fm.fileExists(atPath: chatDB.path) else { return false }
        guard let handle = try? FileHandle(forReadingFrom: chatDB) else { return false }
        try? handle.close()
        return true
    }
}
