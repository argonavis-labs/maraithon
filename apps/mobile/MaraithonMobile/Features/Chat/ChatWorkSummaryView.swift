import SwiftUI

struct ChatWorkSummaryDisclosure: View {
    let summary: ChatWorkSummary
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if !summary.toolCalls.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ChatWorkSummaryViewCopy.checkedSectionTitle)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(summary.toolCalls) { toolCall in
                            ChatToolCallRow(toolCall: toolCall)
                        }
                    }
                } else if !summary.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ChatWorkSummaryViewCopy.progressSectionTitle)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(summary.steps.prefix(4)) { step in
                            ChatWorkStepRow(step: step)
                        }
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Label(summary.headline ?? ChatWorkSummaryViewCopy.completedFallbackTitle, systemImage: "checklist")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .tint(.secondary)
    }
}

struct ChatPendingWorkSummary: View {
    let summary: ChatWorkSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)

                Text(summary?.headline ?? ChatWorkSummaryViewCopy.pendingFallbackTitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let summary, !summary.toolCalls.isEmpty {
                ChatToolCallStrip(toolCalls: summary.toolCalls)
            }
        }
    }
}

enum ChatWorkSummaryViewCopy {
    static let checkedSectionTitle = "Sources and actions"
    static let progressSectionTitle = "Assistant activity"
    static let completedFallbackTitle = "How Maraithon answered"
    static let pendingFallbackTitle = "Preparing your answer"
}

private struct ChatToolCallStrip: View {
    let toolCalls: [ChatToolCallSummary]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(toolCalls.prefix(4)) { toolCall in
                    Label(toolCall.label, systemImage: statusSymbol(for: toolCall.status))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func statusSymbol(for status: String?) -> String {
        switch status {
        case "failed":
            "exclamationmark.triangle"
        case "running":
            "arrow.triangle.2.circlepath"
        default:
            "checkmark.circle"
        }
    }
}

private struct ChatToolCallRow: View {
    let toolCall: ChatToolCallSummary

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: statusSymbol)
                .font(.caption)
                .foregroundStyle(statusColor)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(toolCall.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let summary = toolCall.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var statusSymbol: String {
        switch toolCall.status {
        case "failed":
            "exclamationmark.triangle.fill"
        case "running":
            "arrow.triangle.2.circlepath"
        default:
            "checkmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch toolCall.status {
        case "failed":
            .red
        case "running":
            .secondary
        default:
            .green
        }
    }
}

private struct ChatWorkStepRow: View {
    let step: ChatWorkStepSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
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
