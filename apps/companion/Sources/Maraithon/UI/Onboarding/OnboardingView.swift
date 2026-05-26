import SwiftUI

/// Hosts the active onboarding step and a progress indicator across the
/// four visible steps. Each step view already handles its own layout;
/// this view's job is purely composition + transitions.
///
/// HIG note: animations are SwiftUI defaults (`.transition(.opacity)`,
/// `withAnimation` without overrides). The progress indicator is the
/// system `ProgressView(value:)` — no custom chrome.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env

    /// Flow controller owned by `AppEnvironment`. Passed in so previews
    /// and tests can drive the view directly.
    let flow: OnboardingFlow

    var body: some View {
        VStack(spacing: 0) {
            progressHeader

            ZStack {
                stepContent
                    .transition(.opacity)
                    .id(flow.current)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.default, value: flow.current)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch flow.current {
        case .connect:
            ConnectView()
        case .whatWeSync:
            WhatWeSyncView(onContinue: { flow.advance() })
        case .fullDiskAccess:
            FullDiskAccessView(
                onContinue: { flow.advance() },
                onSkip: {
                    flow.markFullDiskAccessSkipped()
                    flow.markComplete()
                    // Skipping FDA jumps over the backfill choice; the
                    // user can still set a window from Settings later.
                    while flow.current != .done {
                        flow.advance()
                    }
                }
            )
        case .backfill:
            BackfillSetupView(onComplete: { choice in
                env.eventLog.info(
                    "onboarding.backfill_chosen",
                    source: .ui,
                    payload: choice.logPayload
                )
                flow.markComplete()
                flow.advance()
            })
        case .done:
            // Terminal — the host view (`RootWindow`) swaps in the main
            // split view as soon as `flow.current == .done`. Render an
            // empty placeholder defensively.
            Color.clear
        }
    }

    private var progressHeader: some View {
        VStack(spacing: Tokens.Spacing.small) {
            ProgressView(value: flow.progress)
                .progressViewStyle(.linear)
                .accessibilityLabel("Onboarding progress")
                .accessibilityValue(progressAccessibilityValue)

            HStack {
                ForEach(OnboardingFlow.Step.progressSteps, id: \.self) { step in
                    Text(stepLabel(step))
                        .font(.footnote)
                        .foregroundStyle(step == flow.current ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, Tokens.Spacing.xlarge)
        .padding(.top, Tokens.Spacing.medium)
        .padding(.bottom, Tokens.Spacing.small)
    }

    private func stepLabel(_ step: OnboardingFlow.Step) -> String {
        switch step {
        case .connect: return "Connect"
        case .whatWeSync: return "What we sync"
        case .fullDiskAccess: return "Full Disk Access"
        case .backfill: return "Backfill"
        case .done: return ""
        }
    }

    private var progressAccessibilityValue: String {
        switch flow.current {
        case .connect: return "Step 1 of 4 — Connect"
        case .whatWeSync: return "Step 2 of 4 — What we sync"
        case .fullDiskAccess: return "Step 3 of 4 — Full Disk Access"
        case .backfill: return "Step 4 of 4 — Backfill"
        case .done: return "Complete"
        }
    }
}
