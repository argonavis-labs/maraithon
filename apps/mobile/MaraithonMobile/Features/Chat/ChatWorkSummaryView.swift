import SwiftUI

struct ChatWorkSummaryDisclosure: View {
    let summary: ChatWorkSummary
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let summaryText = summary.summary, !summaryText.isEmpty {
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !summary.toolCalls.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(summary.toolCalls) { toolCall in
                            ChatToolCallRow(toolCall: toolCall)
                        }
                    }
                } else if !summary.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(summary.steps) { step in
                            ChatWorkStepRow(step: step)
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 7) {
                if stepCount > 0 {
                    ChatStepCountBadge(count: stepCount)
                }

                Text(disclosureTitle)
                    .lineLimit(2)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .tint(.secondary)
    }

    private var stepCount: Int {
        max(summary.toolCalls.count, summary.steps.count)
    }

    private var disclosureTitle: String {
        if stepCount > 0 {
            return ChatWorkSummaryViewCopy.stepsCompletedTitle(for: stepCount)
        }

        return summary.headline ?? summary.summary ?? ChatWorkSummaryViewCopy.completedFallbackTitle
    }
}

struct ChatPendingWorkSummary: View {
    let summary: ChatWorkSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)

                Text(summary?.headline ?? summary?.summary ?? ChatWorkSummaryViewCopy.pendingFallbackTitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if !visibleSteps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if hiddenStepCount > 0 {
                        Text(ChatWorkSummaryViewCopy.earlierStepsTitle(for: hiddenStepCount))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tertiary)
                    }

                    ForEach(visibleSteps) { step in
                        ChatLiveStepRow(step: step)
                    }
                }
            } else if let toolCalls = summary?.toolCalls, !toolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(toolCalls.suffix(Self.maxVisibleSteps)) { toolCall in
                        ChatToolCallRow(toolCall: toolCall)
                    }
                }
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

private struct ChatStepCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color(uiColor: .separator), lineWidth: 1)
            )
    }
}

private struct ChatLiveStepRow: View {
    let step: ChatWorkStepSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            statusIcon
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(step.displayTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(step.status == "running" ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)

                if let detail = step.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch step.status {
        case "running":
            ProgressView()
                .controlSize(.mini)
        case "failed":
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        default:
            Image(systemName: ChatStepIconography.systemImage(for: step.type))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ChatToolCallRow: View {
    let toolCall: ChatToolCallSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            statusIcon
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(toolCall.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)

                    if let detail = toolCall.detail, !detail.isEmpty {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if let summary = toolCall.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch toolCall.status {
        case "running":
            ProgressView()
                .controlSize(.mini)
        case "failed":
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        default:
            Image(systemName: ChatStepIconography.toolSystemImage(for: toolCall.tool))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ChatWorkStepRow: View {
    let step: ChatWorkStepSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: step.status == "failed" ? "exclamationmark.triangle.fill" : ChatStepIconography.systemImage(for: step.type))
                .font(.caption2)
                .foregroundStyle(step.status == "failed" ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(step.displayTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)

                if let detail = step.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
