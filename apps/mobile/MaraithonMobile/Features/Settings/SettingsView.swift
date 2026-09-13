import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(SessionStore.self) private var sessionStore
    @State private var identity: MobileAPIClient.IdentityResponse.Identity?
    @State private var schedule: MobileAPIClient.MorningSchedule?
    @State private var isEditingIdentity = false
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Form {
                ThemedListHeader {
                    RunnerPageHeader(title: "Settings")
                }

                ThemedListSection("Account") {
                    if let email = sessionStore.user?.email {
                        ThemedValueRow(label: "Email", value: email)
                    }
                    Button {
                        isEditingIdentity = true
                    } label: {
                        ThemedActionRow(title: "About you", systemImage: "person.crop.circle")
                    }
                    .disabled(identity == nil)
                }

                ThemedListSection("Morning brief") {
                    if let schedule {
                        ThemedValueRow(label: "Refresh", value: schedule.displayTime)
                        ThemedValueRow(label: "Time zone", value: schedule.timezoneLabel)
                        if !schedule.configured {
                            ThemedNoteRow("Morning briefing is not configured.")
                        }
                    } else {
                        ThemedNoteRow(isLoading ? "Loading schedule…" : "Schedule is unavailable.")
                    }
                }

                ThemedListSection {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        ThemedActionRow(
                            title: "Notifications & permissions",
                            systemImage: "bell",
                            trailingSystemImage: "arrow.up.right"
                        )
                    }
                }

                if let errorMessage {
                    ThemedListSection {
                        ThemedNoteRow(errorMessage)
                        Button("Retry") { Task { await load() } }
                            .font(Runner.Typography.bodyMedium)
                            .foregroundStyle(Runner.Palette.accent)
                    }
                }

                ThemedListSection {
                    ThemedValueRow(label: "Version", value: version)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .runnerPage()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
            .sheet(isPresented: $isEditingIdentity) {
                if let identity {
                    IdentityOnboardingView(prefill: identity) {
                        isEditingIdentity = false
                        Task { await load() }
                    }
                }
            }
        }
    }

    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "\(version) (\(build))"
    }

    private func load() async {
        guard let token = sessionStore.user?.sessionToken else {
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            async let identity = MobileAPIClient().getIdentity(sessionToken: token)
            async let briefs = MobileAPIClient().loadDailyBriefs(sessionToken: token, limit: 1)
            let results = try await (identity, briefs)
            self.identity = results.0
            schedule = results.1.morningSchedule
            errorMessage = nil
        } catch {
            errorMessage = MobileErrorCopy.message(for: error)
        }
    }
}

// MARK: - Themed list and form pieces

/// Page header row at the top of a `List`/`Form`: sits on the ground with no
/// row chrome so the big title reads as part of the page, not a cell.
struct ThemedListHeader<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Section {
            content()
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: Runner.Spacing.small, leading: 0, bottom: 0, trailing: 0))
        }
    }
}

/// `List`/`Form` section on the workspace ground: ground-colored rows,
/// hairline separators, and an optional uppercase section label.
struct ThemedListSection<Content: View>: View {
    let title: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        Section {
            Group {
                content()
            }
            .listRowBackground(Runner.Palette.background)
            .listRowSeparatorTint(Runner.Palette.border)
        } header: {
            if let title {
                RunnerSectionLabel(title)
            }
        }
    }
}

/// Label on the left in ink, value on the right muted.
struct ThemedValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Runner.Spacing.small) {
            Text(label)
                .font(Runner.Typography.body)
                .foregroundStyle(Runner.Palette.foreground)
            Spacer(minLength: Runner.Spacing.small)
            Text(value)
                .font(Runner.Typography.small.monospacedDigit())
                .foregroundStyle(Runner.Palette.mutedForeground)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Button label for a row that opens something: leading glyph, ink title,
/// trailing chevron (or another affordance glyph).
struct ThemedActionRow: View {
    let title: String
    let systemImage: String
    var trailingSystemImage: String = "chevron.right"
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: Runner.Spacing.tight) {
            Image(systemName: systemImage)
                .font(Runner.Typography.small)
                .foregroundStyle(Runner.Palette.mutedForeground)
                .frame(width: Runner.Spacing.roomy)
                .accessibilityHidden(true)
            Text(title)
                .font(Runner.Typography.body)
                .foregroundStyle(Runner.Palette.foreground)
            Spacer(minLength: Runner.Spacing.small)
            Image(systemName: trailingSystemImage)
                .font(Runner.Typography.caption)
                .foregroundStyle(Runner.Palette.mutedForeground)
                .accessibilityHidden(true)
        }
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(Rectangle())
    }
}

/// Muted explanatory row.
struct ThemedNoteRow: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Runner.Typography.small)
            .foregroundStyle(Runner.Palette.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Inline loading row for lists that fetch on appear.
struct ThemedLoadingRow: View {
    let title: String

    var body: some View {
        HStack(spacing: Runner.Spacing.snug) {
            ProgressView()
                .tint(Runner.Palette.mutedForeground)
            Text(title)
                .font(Runner.Typography.small)
                .foregroundStyle(Runner.Palette.mutedForeground)
        }
    }
}
