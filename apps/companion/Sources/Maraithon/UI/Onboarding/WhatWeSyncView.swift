import SwiftUI

/// Second onboarding step. A plain-text "what we sync, plainly" screen
/// sandwiched between Connect and Full Disk Access so the user reads the
/// scope of data collection before being asked to grant the system
/// permission.
///
/// Invariants:
///   - No decorative chrome. Two `Group`-style lists ("We sync" / "We
///     don't"), one row per item, each row a leading SF Symbol + label.
///   - Primary CTA continues the flow. The secondary "Skip" button advances
///     without recording an opt-out — the user can always revisit the
///     story in Settings → Privacy later.
struct WhatWeSyncView: View {
    @Environment(AppEnvironment.self) private var env

    /// Called when the user presses the primary CTA.
    var onContinue: () -> Void = {}

    /// Called when the user presses Skip. Defaults to the same handler
    /// as `onContinue` — there is no separate "skipped" branch, but the
    /// host view can override to record telemetry.
    var onSkip: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: Tokens.Spacing.large) {
                header

                bulletColumns

                Spacer(minLength: Tokens.Spacing.medium)

                actions
                    .frame(maxWidth: 320)
            }
            .padding(.horizontal, Tokens.Spacing.xlarge)
            .padding(.vertical, Tokens.Spacing.xlarge)
            .frame(maxWidth: Tokens.Layout.onboardingMaxWidth)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(spacing: Tokens.Spacing.small) {
            Image(systemName: "checklist")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: Tokens.IconSize.large, height: Tokens.IconSize.large)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("What we sync, plainly")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text("Maraithon mirrors local context to your assistant so it can answer questions about your life. Here's exactly what crosses the line — and what doesn't.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var bulletColumns: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.large) {
            BulletSection(
                title: "We sync",
                tone: .good,
                rowSymbol: "checkmark",
                items: Self.synced
            )
            BulletSection(
                title: "We don't sync",
                tone: .muted,
                rowSymbol: "minus",
                items: Self.notSynced
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        VStack(spacing: Tokens.Spacing.small) {
            Button {
                onContinue()
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Continue onboarding")

            Button {
                env.eventLog.info("onboarding.what_we_sync.skipped", source: .ui)
                (onSkip ?? onContinue)()
            } label: {
                Text("Skip")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .accessibilityLabel("Skip past data summary")
        }
    }

    /// Plain-language list of what gets synced. Order matches the
    /// product copy in the spec.
    static let synced: [String] = [
        "iMessage",
        "Notes",
        "Voice Memos + transcripts",
        "Calendar",
        "Reminders",
        "Documents in ~/Documents",
        "Browser history"
    ]

    /// Plain-language list of what is excluded. Each entry is a phrase,
    /// not a sentence, so the layout reads as a checklist.
    static let notSynced: [String] = [
        "Encrypted disks",
        ".ssh keys and identities",
        ".env files",
        "Banking and brokerage sites",
        "Medical portals",
        "Search engine queries"
    ]
}

/// Row group used by `WhatWeSyncView`. Section header + leading-icon list.
private struct BulletSection: View {
    let title: String
    let tone: StatusTone
    let rowSymbol: String
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            SectionHeader(title)
            VStack(alignment: .leading, spacing: Tokens.Spacing.xsmall) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.small) {
                        Image(systemName: rowSymbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tone.color)
                            .frame(width: Tokens.IconSize.inline, alignment: .leading)
                            .accessibilityHidden(true)
                        Text(item)
                            .font(.body)
                            .foregroundStyle(.primary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(title): \(item)")
                }
            }
        }
    }
}

#Preview {
    WhatWeSyncView()
        .frame(width: 720, height: 620)
}
