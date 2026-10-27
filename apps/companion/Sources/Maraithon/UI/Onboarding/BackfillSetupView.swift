import SwiftUI

enum BackfillSetupCopy {
    static let stepLabel = "History"
    static let progressAccessibilityValue = "Step 4 of 4 — History"
    static let startButtonTitle = "Start with this history"
    static let skipButtonTitle = "Start fresh"
    static let skipAccessibilityLabel = "Start fresh without importing older history"
}

/// Final onboarding step. The user picks how much message history to
/// make available on first connect.
///
/// v4: surfaces a single `Picker` for the preset windows (30 / 60 / 90 /
/// 180 days) plus a custom "From a specific date" option that reveals a
/// `DatePicker`. Defaults to 90 days because that's where the assistant
/// stops feeling thin without making the first import feel like it never
/// finishes.
///
/// This view *records* the choice via `onComplete`; sources are
/// responsible for honouring it on the next polling tick.
struct BackfillSetupView: View {
    /// Preset windows shown in the dropdown. `.custom` is sentinel — it
    /// reveals a `DatePicker` and the final emitted choice is
    /// `.fromDate(...)`.
    enum Window: String, Identifiable, CaseIterable, Hashable {
        case last30
        case last60
        case last90
        case last180
        case custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .last30: return "Last 30 days"
            case .last60: return "Last 60 days"
            case .last90: return "Last 90 days (recommended)"
            case .last180: return "Last 180 days"
            case .custom: return "From a specific date…"
            }
        }
    }

    /// Outward-facing choice handed to the iMessage source. `.fromDate`
    /// carries an absolute lower bound; preset windows are converted to
    /// absolute dates at the call site so the source never needs to
    /// re-resolve "today".
    enum Choice: Hashable, Sendable {
        case last(days: Int)
        case fromDate(Date)
        case fresh

        /// Stable string for logging. Avoid leaking the absolute date —
        /// the day count or "custom" is enough for diagnostics.
        var logPayload: [String: String] {
            switch self {
            case .last(let days): return ["choice": "last_\(days)_days"]
            case .fromDate: return ["choice": "custom_date"]
            case .fresh: return ["choice": "fresh"]
            }
        }
    }

    /// Called with the user's choice when they confirm.
    var onComplete: (Choice) -> Void = { _ in }

    @State private var window: Window = .last90
    @State private var customDate: Date = Date().addingTimeInterval(-60 * 60 * 24 * 90)

    var body: some View {
        VStack(spacing: Tokens.Spacing.large) {
            Spacer(minLength: 0)

            Image(systemName: "clock.arrow.circlepath")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: Tokens.IconSize.large, height: Tokens.IconSize.large)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: Tokens.Spacing.small) {
                Text("How much history?")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text("Choose how far back to pull history on this Mac. You can extend the window later from Settings.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                Section {
                    Picker("History window", selection: $window) {
                        ForEach(Window.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    if window == .custom {
                        DatePicker(
                            "Start date",
                            selection: $customDate,
                            in: ...Date(),
                            displayedComponents: .date
                        )
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 360)

            VStack(spacing: Tokens.Spacing.small) {
                Button {
                    onComplete(resolvedChoice)
                } label: {
                    Text(BackfillSetupCopy.startButtonTitle)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Button {
                    onComplete(.fresh)
                } label: {
                    Text(BackfillSetupCopy.skipButtonTitle)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .accessibilityLabel(BackfillSetupCopy.skipAccessibilityLabel)
            }
            .frame(maxWidth: 280)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.Spacing.xlarge)
        .padding(.vertical, Tokens.Spacing.xlarge)
        .frame(maxWidth: Tokens.Layout.onboardingMaxWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Translate the current selection into an emitted `Choice`. Centralised
    /// so the primary button is the only spot that needs to know
    /// about the picker → choice mapping.
    private var resolvedChoice: Choice {
        switch window {
        case .last30: return .last(days: 30)
        case .last60: return .last(days: 60)
        case .last90: return .last(days: 90)
        case .last180: return .last(days: 180)
        case .custom: return .fromDate(customDate)
        }
    }
}

#Preview {
    BackfillSetupView()
        .frame(width: 720, height: 620)
}
