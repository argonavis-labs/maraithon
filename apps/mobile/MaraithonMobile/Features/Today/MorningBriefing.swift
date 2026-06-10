import SwiftUI

/// Grouping of open work under the morning briefing, mirroring the web
/// briefing page: decisions first, then the channel the work came from.
enum BriefingGroups {
    struct Group: Identifiable {
        let key: String
        let title: String
        let todos: [TodoItem]

        var id: String { key }
    }

    static let groupRowLimit = 6

    static func groups(
        todos: [TodoItem],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Group] {
        let open = todos.filter { !$0.isCompleted }
        let decisions = TodoFiltering.filter(open, by: .decisions, now: now, calendar: calendar)
        let decisionIDs = Set(decisions.map(\.id))
        let remaining = open.filter { !decisionIDs.contains($0.id) }

        func bySource(_ sources: Set<String>) -> [TodoItem] {
            remaining.filter { sources.contains($0.sourceSystem ?? "") }
        }

        let definitions: [(key: String, title: String, todos: [TodoItem])] = [
            ("decisions", "Decisions to make", decisions),
            ("gmail", "Gmail", bySource(["gmail", "gmail_triage"])),
            ("slack", "Slack", bySource(["slack"])),
            ("calendar", "Calendar", bySource(["calendar", "google_calendar", "calendar_local"]))
        ]

        return definitions
            .map { Group(key: $0.key, title: $0.title, todos: Array($0.todos.prefix(groupRowLimit))) }
            .filter { !$0.todos.isEmpty }
    }
}

/// Hero card for today's morning briefing on the Today tab.
struct MorningBriefingCard: View {
    let brief: MobileAPIClient.RemoteBrief

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(MorningBriefingCopy.sectionTitle, systemImage: "sunrise.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)

                Spacer(minLength: 8)

                if let date = brief.referenceDate {
                    Text(MorningBriefingCopy.dayLabel(for: date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(brief.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let summary = brief.summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 4) {
                Text(MorningBriefingCopy.readBriefingTitle)
                Image(systemName: "chevron.right")
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.accentColor)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }
}

/// Full briefing content — used for today's briefing and the scrollback.
struct BriefDetailView: View {
    let brief: MobileAPIClient.RemoteBrief

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    if let date = brief.referenceDate {
                        Text(MorningBriefingCopy.dayLabel(for: date))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                    }

                    Text(brief.title)
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    if let summary = brief.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(MorningBriefingCopy.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var blocks: [BriefMarkdown.Block] {
        BriefMarkdown.blocks(from: brief.body ?? "")
    }

    @ViewBuilder
    private func blockView(_ block: BriefMarkdown.Block) -> some View {
        switch block {
        case .heading(let text):
            Text(text)
                .font(.headline)
                .padding(.top, 4)

        case .bullet(let text):
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                    .foregroundStyle(.secondary)
                Text(BriefMarkdown.inline(text))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .paragraph(let text):
            Text(BriefMarkdown.inline(text))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Minimal parser for the markdown subset the briefing skills emit:
/// ## headings, bullet lines, **bold**, and `code`.
enum BriefMarkdown {
    enum Block: Equatable {
        case heading(String)
        case bullet(String)
        case paragraph(String)
    }

    static func blocks(from body: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }

        for rawLine in body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flushParagraph()
            } else if line.hasPrefix("##") {
                flushParagraph()
                let heading = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(heading))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }

        flushParagraph()
        return blocks
    }

    /// Renders **bold** and `code` through AttributedString markdown,
    /// falling back to plain text when parsing fails.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

/// Compact row for the 7-day briefing scrollback on the Today tab.
struct PreviousBriefRow: View {
    let brief: MobileAPIClient.RemoteBrief

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(brief.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let date = brief.referenceDate {
                    Text(MorningBriefingCopy.dayLabel(for: date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let summary = brief.summary, !summary.isEmpty {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

enum MorningBriefingCopy {
    static let sectionTitle = "Morning briefing"
    static let navigationTitle = "Briefing"
    static let readBriefingTitle = "Read the briefing"
    static let previousSectionTitle = "Previous briefings"

    static func dayLabel(for date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}
