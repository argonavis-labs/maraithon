import SwiftUI

struct ChatWorkSummaryDisclosure: View {
    let summary: ChatWorkSummary
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Runner.Spacing.compact) {
                    if stepCount > 0 {
                        RunnerBadge(text: "\(stepCount)")
                    }

                    Text(disclosureTitle)
                        .font(Runner.Typography.captionMedium)
                        .foregroundStyle(Runner.Palette.mutedForeground)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(Runner.Typography.micro)
                        .foregroundStyle(Runner.Palette.mutedForeground)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isExpanded ? [.isSelected] : [])

            if isExpanded {
                VStack(alignment: .leading, spacing: Runner.Spacing.small) {
                    if let summaryText = summary.summary, !summaryText.isEmpty {
                        Text(summaryText)
                            .font(Runner.Typography.caption)
                            .foregroundStyle(Runner.Palette.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !summary.toolCalls.isEmpty {
                        VStack(alignment: .leading, spacing: Runner.Spacing.compact) {
                            ForEach(summary.toolCalls) { toolCall in
                                ChatToolCallRow(toolCall: toolCall)
                            }
                        }
                    } else if !summary.steps.isEmpty {
                        VStack(alignment: .leading, spacing: Runner.Spacing.compact) {
                            ForEach(summary.steps) { step in
                                ChatWorkStepRow(step: step)
                            }
                        }
                    }
                }
                .padding(.top, Runner.Spacing.small)
            }
        }
    }

    private var stepCount: Int {
        max(summary.toolCalls.count, summary.steps.count)
    }

    private var disclosureTitle: String {
        if let headline = summary.headline, !headline.isEmpty {
            return headline
        }

        if stepCount > 0 {
            return ChatWorkSummaryViewCopy.stepsCompletedTitle(for: stepCount)
        }

        return summary.summary ?? ChatWorkSummaryViewCopy.completedFallbackTitle
    }
}

struct ChatPendingWorkSummary: View {
    let summary: ChatWorkSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: Runner.Spacing.small) {
            HStack(spacing: Runner.Spacing.small) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Runner.Palette.mutedForeground)

                Text(summary?.headline ?? summary?.summary ?? ChatWorkSummaryViewCopy.pendingFallbackTitle)
                    .font(Runner.Typography.small)
                    .foregroundStyle(Runner.Palette.mutedForeground)
                    .lineLimit(2)
            }

            if !visibleSteps.isEmpty {
                VStack(alignment: .leading, spacing: Runner.Spacing.compact) {
                    if hiddenStepCount > 0 {
                        Text(ChatWorkSummaryViewCopy.earlierStepsTitle(for: hiddenStepCount))
                            .font(Runner.Typography.micro)
                            .foregroundStyle(Runner.Palette.mutedForeground)
                    }

                    ForEach(visibleSteps) { step in
                        ChatLiveStepRow(step: step)
                    }
                }
            } else if let toolCalls = summary?.toolCalls, !toolCalls.isEmpty {
                VStack(alignment: .leading, spacing: Runner.Spacing.compact) {
                    ForEach(toolCalls.suffix(Self.maxVisibleSteps)) { toolCall in
                        ChatToolCallRow(toolCall: toolCall)
                    }
                }
            }

            if let preview = summary?.preview, !preview.isEmpty {
                Text(preview + " ▍")
                    .font(Runner.Typography.body)
                    .foregroundStyle(Runner.Palette.foreground80)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.interpolate)
            } else if let thinking = summary?.thinking, !thinking.isEmpty {
                Text(thinking + " ▍")
                    .font(Runner.Typography.caption)
                    .italic()
                    .foregroundStyle(Runner.Palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
                    .contentTransition(.interpolate)
            }
        }
        .animation(.snappy, value: summary?.steps.count ?? 0)
    }

    private static let maxVisibleSteps = 6

    private var visibleSteps: [ChatWorkStepSummary] {
        Array((summary?.steps ?? []).suffix(Self.maxVisibleSteps))
    }

    private var hiddenStepCount: Int {
        max((summary?.steps.count ?? 0) - Self.maxVisibleSteps, 0)
    }
}

enum ChatWorkSummaryViewCopy {
    static let progressSectionTitle = "Assistant activity"
    static let completedFallbackTitle = "How Maraithon answered"
    static let pendingFallbackTitle = "Starting assistant work"

    static func stepsCompletedTitle(for count: Int) -> String {
        count == 1 ? "1 step completed" : "\(count) steps completed"
    }

    static func earlierStepsTitle(for count: Int) -> String {
        count == 1 ? "1 earlier step" : "\(count) earlier steps"
    }
}

/// Status dot colors shared by every step row: running is the accent, failed
/// is destructive, finished steps stay quiet.
private enum ChatStepDot {
    static func color(for status: String?) -> Color {
        switch status {
        case "running":
            Runner.Palette.accent
        case "failed":
            Runner.Palette.destructive
        default:
            Runner.Palette.ring
        }
    }
}

private struct ChatLiveStepRow: View {
    let step: ChatWorkStepSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Runner.Spacing.small) {
            RunnerStatusDot(color: ChatStepDot.color(for: step.status))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + Runner.Spacing.xsmall }

            VStack(alignment: .leading, spacing: 1) {
                Text(step.displayTitle)
                    .font(Runner.Typography.caption)
                    .foregroundStyle(step.status == "running" ? Runner.Palette.foreground : Runner.Palette.mutedForeground)
                    .lineLimit(1)

                if let detail = step.detail, !detail.isEmpty {
                    Text(detail)
                        .font(Runner.Typography.micro)
                        .foregroundStyle(Runner.Palette.mutedForeground)
                        .lineLimit(2)
                }
            }
        }
    }
}

private struct ChatToolCallRow: View {
    let toolCall: ChatToolCallSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Runner.Spacing.small) {
            RunnerStatusDot(color: ChatStepDot.color(for: toolCall.status))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + Runner.Spacing.xsmall }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Runner.Spacing.xsmall + 1) {
                    Text(toolCall.label)
                        .font(Runner.Typography.captionMedium)
                        .foregroundStyle(toolCall.status == "running" ? Runner.Palette.foreground : Runner.Palette.mutedForeground)
                        .lineLimit(1)
                        .layoutPriority(1)

                    if let detail = toolCall.detail, !detail.isEmpty {
                        Text("·")
                            .font(Runner.Typography.caption)
                            .foregroundStyle(Runner.Palette.mutedForeground)

                        Text(detail)
                            .font(Runner.Typography.caption)
                            .foregroundStyle(Runner.Palette.mutedForeground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if let summary = toolCall.summary, !summary.isEmpty {
                    Text(summary)
                        .font(Runner.Typography.micro)
                        .foregroundStyle(Runner.Palette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct ChatWorkStepRow: View {
    let step: ChatWorkStepSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Runner.Spacing.small) {
            RunnerStatusDot(color: ChatStepDot.color(for: step.status))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + Runner.Spacing.xsmall }

            VStack(alignment: .leading, spacing: 1) {
                Text(step.displayTitle)
                    .font(Runner.Typography.captionMedium)
                    .foregroundStyle(Runner.Palette.mutedForeground)

                if let detail = step.detail, !detail.isEmpty {
                    Text(detail)
                        .font(Runner.Typography.micro)
                        .foregroundStyle(Runner.Palette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

enum ChatStepIconography {
    static func systemImage(for stepType: String?) -> String {
        switch stepType {
        case "context":
            "tray.full"
        case "answer_preparation":
            "sparkles"
        case "supporting_plan":
            "list.bullet.rectangle"
        case "reply":
            "text.bubble"
        case "supporting_check":
            "checkmark.circle"
        default:
            "circle.dashed"
        }
    }

    static func toolSystemImage(for tool: String) -> String {
        switch tool {
        case "calendar":
            "calendar"
        case "gmail":
            "envelope"
        case "slack":
            "number"
        case "messages":
            "message"
        case "people", "people_update", "relationship_context", "relationship_learning":
            "person.2"
        case "open_work", "open_work_review", "work_update", "linked_item":
            "checklist"
        case "open_loops", "action_history":
            "arrow.triangle.branch"
        case "memory_check", "memory_update", "memory":
            "brain"
        case "preferences", "preference", "preference_update", "feedback":
            "slider.horizontal.3"
        case "connected_accounts", "connected_sources":
            "link"
        case "draft", "prepared_action":
            "square.and.pencil"
        case "scheduled_task", "scheduled_followups", "briefing_schedule":
            "clock"
        case "notes":
            "note.text"
        case "voice_memos":
            "waveform"
        case "files":
            "doc"
        case "reminders":
            "list.bullet"
        case "browser_history", "local_context":
            "magnifyingglass"
        case "linear", "notaui", "projects", "project_update", "project_run":
            "hammer"
        case "automations", "automation_update", "automation_query":
            "gearshape.2"
        default:
            "checkmark.circle"
        }
    }
}
