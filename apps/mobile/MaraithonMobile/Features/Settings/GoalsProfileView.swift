import SwiftUI

struct GoalsProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var sessionStore

    @State private var goals: [MobileAPIClient.RemoteGoal] = []
    @State private var isLoading = true
    @State private var isShowingNewGoal = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                ThemedListHeader {
                    RunnerPageHeader(title: GoalsProfileCopy.title, count: goals.isEmpty ? nil : goals.count)
                }

                if isLoading {
                    ThemedListSection {
                        ThemedLoadingRow(title: GoalsProfileCopy.loadingTitle)
                    }
                } else if let errorMessage {
                    ThemedListSection {
                        RunnerEmptyState(
                            title: GoalsProfileCopy.loadFailedTitle,
                            description: errorMessage,
                            systemImage: "exclamationmark.triangle"
                        )
                        .listRowSeparator(.hidden)
                    }
                } else if goals.isEmpty {
                    ThemedListSection {
                        RunnerEmptyState(
                            title: GoalsProfileCopy.emptyTitle,
                            description: GoalsProfileCopy.emptyDescription,
                            systemImage: "target"
                        )
                        .listRowSeparator(.hidden)
                    }
                } else {
                    ThemedListSection(GoalsProfileCopy.activeSectionTitle) {
                        ForEach(goals) { goal in
                            GoalProfileRow(goal: goal)
                        }
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .runnerPage()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingNewGoal = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(sessionStore.user?.sessionToken == nil)
                    .accessibilityIdentifier("new-goal-button")
                    .accessibilityLabel(GoalsProfileCopy.newGoalAccessibilityLabel)
                }

                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        Task { await loadGoals() }
                    } label: {
                        Label(GoalsProfileCopy.refreshLabel, systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .task {
                await loadGoals()
            }
            .refreshable {
                await loadGoals()
            }
            .sheet(isPresented: $isShowingNewGoal) {
                GoalEditorView { savedGoal in
                    upsert(savedGoal)
                }
            }
        }
    }

    private func loadGoals() async {
        guard let sessionToken = sessionStore.user?.sessionToken else {
            goals = []
            errorMessage = GoalsProfileCopy.signedOutMessage
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            goals = try await MobileAPIClient().listGoals(
                sessionToken: sessionToken,
                status: "active",
                category: "all",
                limit: 100
            )
        } catch {
            errorMessage = MobileErrorCopy.message(for: error)
        }

        isLoading = false
    }

    private func upsert(_ goal: MobileAPIClient.RemoteGoal) {
        goals.removeAll { $0.id == goal.id }
        goals.insert(goal, at: 0)
        errorMessage = nil
    }
}

private struct GoalProfileRow: View {
    let goal: MobileAPIClient.RemoteGoal

    var body: some View {
        VStack(alignment: .leading, spacing: Runner.Spacing.compact) {
            HStack(alignment: .firstTextBaseline, spacing: Runner.Spacing.small) {
                Text(goal.title)
                    .font(Runner.Typography.bodyMedium)
                    .foregroundStyle(Runner.Palette.foreground)
                    .lineLimit(2)

                Spacer(minLength: Runner.Spacing.small)

                StatusPill(
                    title: GoalsProfileCopy.categoryTitle(goal.category),
                    tint: GoalsProfileCopy.categoryTint(goal.category)
                )
            }

            if let desiredOutcome = goal.desiredOutcome?.trimmingCharacters(in: .whitespacesAndNewlines),
               !desiredOutcome.isEmpty {
                Text(desiredOutcome)
                    .font(Runner.Typography.small)
                    .foregroundStyle(Runner.Palette.mutedForeground)
                    .lineLimit(3)
            }

            HStack(spacing: Runner.Spacing.snug) {
                Label(GoalsProfileCopy.statusTitle(goal.status), systemImage: "circle.fill")
                Label(GoalsProfileCopy.reviewTitle(goal.reviewCadence), systemImage: "calendar.badge.clock")

                if goal.linkedWorkCount > 0 {
                    Label("\(goal.linkedWorkCount) work", systemImage: "checklist")
                }
            }
            .font(Runner.Typography.caption)
            .foregroundStyle(Runner.Palette.mutedForeground)
            .lineLimit(1)

            if let progress = goal.latestProgress,
               let summary = progress.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                Text(summary)
                    .font(Runner.Typography.caption)
                    .foregroundStyle(Runner.Palette.mutedForeground)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, Runner.Spacing.xsmall)
    }
}

private struct GoalEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var sessionStore

    let onSaved: (MobileAPIClient.RemoteGoal) -> Void

    @State private var title = ""
    @State private var desiredOutcome = ""
    @State private var why = ""
    @State private var successMetric = ""
    @State private var category: GoalEditorCategory = .work
    @State private var reviewCadence: GoalEditorCadence = .weekly
    @State private var priority = 50
    @State private var sensitivity: GoalEditorSensitivity = .standard
    @State private var proactiveVisibility: GoalEditorVisibility = .summary
    @State private var hasTargetDate = false
    @State private var targetDate = Date()
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                ThemedListHeader {
                    RunnerPageHeader(title: GoalEditorCopy.navigationTitle)
                }

                ThemedListSection(GoalEditorCopy.goalSectionTitle) {
                    TextField(GoalEditorCopy.titlePlaceholder, text: $title)
                        .font(Runner.Typography.body)
                        .foregroundStyle(Runner.Palette.foreground)
                        .accessibilityIdentifier("goal-title-field")

                    TextField(GoalEditorCopy.outcomePlaceholder, text: $desiredOutcome, axis: .vertical)
                        .font(Runner.Typography.body)
                        .foregroundStyle(Runner.Palette.foreground)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("goal-outcome-field")

                    TextField(GoalEditorCopy.whyPlaceholder, text: $why, axis: .vertical)
                        .font(Runner.Typography.body)
                        .foregroundStyle(Runner.Palette.foreground)
                        .lineLimit(2...4)

                    TextField(GoalEditorCopy.metricPlaceholder, text: $successMetric, axis: .vertical)
                        .font(Runner.Typography.body)
                        .foregroundStyle(Runner.Palette.foreground)
                        .lineLimit(2...4)
                }

                ThemedListSection(GoalEditorCopy.categorySectionTitle) {
                    Picker(GoalEditorCopy.categoryPickerTitle, selection: $category) {
                        ForEach(GoalEditorCategory.allCases) { category in
                            Label(category.title, systemImage: category.systemImage)
                                .tag(category)
                        }
                    }
                    .font(Runner.Typography.body)
                    .foregroundStyle(Runner.Palette.foreground)

                    Stepper(value: $priority, in: 0...100, step: 5) {
                        ThemedValueRow(label: GoalEditorCopy.priorityLabel, value: "\(priority)")
                    }

                    Picker(GoalEditorCopy.reviewPickerTitle, selection: $reviewCadence) {
                        ForEach(GoalEditorCadence.allCases) { cadence in
                            Text(cadence.title).tag(cadence)
                        }
                    }
                    .font(Runner.Typography.body)
                    .foregroundStyle(Runner.Palette.foreground)
                }

                ThemedListSection(GoalEditorCopy.privacySectionTitle) {
                    Picker(GoalEditorCopy.sensitivityPickerTitle, selection: $sensitivity) {
                        ForEach(GoalEditorSensitivity.allCases) { sensitivity in
                            Text(sensitivity.title).tag(sensitivity)
                        }
                    }
                    .font(Runner.Typography.body)
                    .foregroundStyle(Runner.Palette.foreground)

                    Picker(GoalEditorCopy.visibilityPickerTitle, selection: $proactiveVisibility) {
                        ForEach(GoalEditorVisibility.allCases) { visibility in
                            Text(visibility.title).tag(visibility)
                        }
                    }
                    .font(Runner.Typography.body)
                    .foregroundStyle(Runner.Palette.foreground)
                }

                ThemedListSection(GoalEditorCopy.timingSectionTitle) {
                    Toggle(GoalEditorCopy.targetDateToggleTitle, isOn: $hasTargetDate)
                        .font(Runner.Typography.body)
                        .foregroundStyle(Runner.Palette.foreground)

                    if hasTargetDate {
                        DatePicker(
                            GoalEditorCopy.targetDatePickerTitle,
                            selection: $targetDate,
                            displayedComponents: [.date]
                        )
                        .font(Runner.Typography.body)
                        .foregroundStyle(Runner.Palette.foreground)
                    }
                }

                if let errorMessage {
                    ThemedListSection {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(Runner.Typography.small)
                            .foregroundStyle(Runner.Palette.destructiveText)
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .runnerPage()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? GoalEditorCopy.savingButtonTitle : GoalEditorCopy.saveButtonTitle) {
                        Task { await save() }
                    }
                    .disabled(isSaving || !canSave)
                    .accessibilityIdentifier("goal-save-button")
                }
            }
            .onChange(of: category) { _, newCategory in
                applyDefaults(for: newCategory)
            }
        }
    }

    private var canSave: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4 &&
            desiredOutcome.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8
    }

    private func save() async {
        guard let sessionToken = sessionStore.user?.sessionToken else {
            errorMessage = GoalEditorCopy.signedOutMessage
            return
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let goal = try await MobileAPIClient().createGoal(
                sessionToken: sessionToken,
                payload: payload()
            )
            onSaved(goal)
            dismiss()
        } catch {
            errorMessage = MobileErrorCopy.message(for: error)
        }
    }

    private func payload() -> MobileAPIClient.RequestBody {
        var payload: MobileAPIClient.RequestBody = [
            "title": .string(title.trimmingCharacters(in: .whitespacesAndNewlines)),
            "category": .string(category.rawValue),
            "desired_outcome": .string(desiredOutcome.trimmingCharacters(in: .whitespacesAndNewlines)),
            "review_cadence": .string(reviewCadence.rawValue),
            "priority": .int(priority),
            "sensitivity": .string(sensitivity.rawValue),
            "proactive_visibility": .string(proactiveVisibility.rawValue)
        ]

        let trimmedWhy = why.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedWhy.isEmpty {
            payload["why"] = .string(trimmedWhy)
        }

        let trimmedMetric = successMetric.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedMetric.isEmpty {
            payload["success_metric"] = .string(trimmedMetric)
        }

        if hasTargetDate {
            payload["target_at"] = .string(Self.targetDateString(targetDate))
        }

        return payload
    }

    private func applyDefaults(for category: GoalEditorCategory) {
        if category == .life {
            reviewCadence = .monthly
        } else if reviewCadence == .monthly {
            reviewCadence = .weekly
        }

        if category == .work {
            sensitivity = .standard
            proactiveVisibility = .summary
        } else if sensitivity == .standard {
            sensitivity = .sensitive
            proactiveVisibility = .summary
        }
    }

    private static func targetDateString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let normalized = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: components.year,
            month: components.month,
            day: components.day,
            hour: 12,
            minute: 0,
            second: 0
        )) ?? date

        return ISO8601DateFormatter().string(from: normalized)
    }
}

private enum GoalEditorCategory: String, CaseIterable, Identifiable {
    case work
    case person
    case healthFitness = "health_fitness"
    case life

    var id: String { rawValue }

    var title: String {
        switch self {
        case .work:
            "Work"
        case .person:
            "Person"
        case .healthFitness:
            "Health and Fitness"
        case .life:
            "Life"
        }
    }

    var systemImage: String {
        switch self {
        case .work:
            "briefcase"
        case .person:
            "person.crop.circle"
        case .healthFitness:
            "figure.run"
        case .life:
            "sparkles"
        }
    }
}

private enum GoalEditorCadence: String, CaseIterable, Identifiable {
    case daily
    case weekly
    case monthly
    case manual

    var id: String { rawValue }

    var title: String {
        rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private enum GoalEditorSensitivity: String, CaseIterable, Identifiable {
    case standard
    case sensitive
    case `private`

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }
}

private enum GoalEditorVisibility: String, CaseIterable, Identifiable {
    case full
    case summary
    case none

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }
}

private enum GoalsProfileCopy {
    static let title = "Goals"
    static let loadingTitle = "Loading Goals"
    static let loadFailedTitle = "Could Not Load Goals"
    static let emptyTitle = "No Goals"
    static let emptyDescription = "Add goals here so Maraithon can keep your work, people, health, and life context aligned."
    static let signedOutMessage = "Sign in to manage goals."
    static let activeSectionTitle = "Active"
    static let refreshLabel = "Refresh Goals"
    static let newGoalAccessibilityLabel = "New Goal"

    static func categoryTitle(_ category: String) -> String {
        switch category {
        case "health_fitness":
            "Health"
        default:
            category.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func statusTitle(_ status: String) -> String {
        status.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func reviewTitle(_ cadence: String) -> String {
        cadence.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func categoryTint(_ category: String) -> Color {
        switch category {
        case "work":
            .blue
        case "person":
            .purple
        case "health_fitness":
            .green
        case "life":
            .orange
        default:
            Runner.Palette.mutedForeground
        }
    }
}

private enum GoalEditorCopy {
    static let navigationTitle = "New Goal"
    static let savingButtonTitle = "Saving"
    static let saveButtonTitle = "Save"
    static let signedOutMessage = "Sign in to add goals."
    static let goalSectionTitle = "Goal"
    static let titlePlaceholder = "Goal title"
    static let outcomePlaceholder = "Desired outcome"
    static let whyPlaceholder = "Why it matters"
    static let metricPlaceholder = "Success metric"
    static let categorySectionTitle = "Review"
    static let categoryPickerTitle = "Category"
    static let priorityLabel = "Priority"
    static let reviewPickerTitle = "Cadence"
    static let privacySectionTitle = "Privacy"
    static let sensitivityPickerTitle = "Sensitivity"
    static let visibilityPickerTitle = "Visibility"
    static let timingSectionTitle = "Target"
    static let targetDateToggleTitle = "Add target date"
    static let targetDatePickerTitle = "Target date"
}
