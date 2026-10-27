import SwiftUI

/// Grouping of open work under the morning briefing. Today leads, current
/// work follows in recency order, and past-due work remains visible last.
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
        let open = TodoFiltering.filter(todos, by: .needsAction, now: now, calendar: calendar)
        let today = TodoFiltering.filter(open, by: .today, now: now, calendar: calendar)
        let overdue = TodoFiltering.filter(open, by: .overdue, now: now, calendar: calendar)
        let todayIDs = Set(today.map(\.id))
        let overdueIDs = Set(overdue.map(\.id))
        let current = open.filter { !todayIDs.contains($0.id) && !overdueIDs.contains($0.id) }
        let recent = TodoFiltering.filter(
            current,
            by: .needsAction,
            now: now,
            calendar: calendar
        )

        let definitions: [(key: String, title: String, todos: [TodoItem])] = [
            ("today", "Today", today),
            ("recent", "Needs action", recent),
            ("overdue", "Past due", overdue)
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
        RunnerCard {
            VStack(alignment: .leading, spacing: Runner.Spacing.small) {
                HStack {
                    Label(MorningBriefingCopy.sectionTitle, systemImage: "sunrise.fill")
                        .font(Runner.Typography.captionMedium)
                        .foregroundStyle(Runner.Palette.accent)

                    Spacer(minLength: Runner.Spacing.small)

                    if let date = brief.referenceDate {
                        Text(MorningBriefingCopy.dayLabel(for: date))
                            .font(Runner.Typography.caption)
                            .foregroundStyle(Runner.Palette.mutedForeground)
                    }
                }

                Text(brief.title)
                    .font(Runner.Typography.bodySemibold)
                    .foregroundStyle(Runner.Palette.foreground)
                    .fixedSize(horizontal: false, vertical: true)

                if let summary = brief.summary, !summary.isEmpty {
                    Text(summary)
                        .font(Runner.Typography.small)
                        .foregroundStyle(Runner.Palette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: Runner.Spacing.xsmall) {
                    Text(MorningBriefingCopy.readBriefingTitle)
                    Image(systemName: "chevron.right")
                }
                .font(Runner.Typography.smallMedium)
                .foregroundStyle(Runner.Palette.accent)
            }
            .padding(Runner.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Full briefing content — used for today's briefing and the scrollback.
struct BriefDetailView: View {
    let brief: MobileAPIClient.RemoteBrief

    /// Parsed once at construction; the brief body is immutable for the life
    /// of this view, so re-parsing markdown per render was pure waste. Blocks
    /// are identified by their (stable) index within each section.
    private let sections: [DailyBriefSections.Section]

    init(brief: MobileAPIClient.RemoteBrief) {
        self.brief = brief
        self.sections = DailyBriefSections.sections(from: brief.body ?? "", title: brief.title)
    }

    private var summary: String? {
        guard let summary = brief.summary, !summary.isEmpty else { return nil }
        return summary
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                RunnerPageHeader(
                    eyebrow: brief.referenceDate.map { MorningBriefingCopy.dayLabel(for: $0) },
                    title: brief.title,
                    subtitle: summary
                )

                VStack(alignment: .leading, spacing: Runner.Spacing.large) {
                    ForEach(sections) { section in
                        BriefSectionView(section: section, endTimes: brief.calendarEndTimes)
                    }
                }
            }
            .padding(.horizontal, Runner.Layout.pageInset)
            .padding(.top, Runner.Spacing.small)
            .padding(.bottom, Runner.Spacing.xlarge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(MorningBriefingCopy.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .runnerPage()
    }
}

/// The visible clock updates row emphasis without refreshing the saved brief.
struct BriefSectionView: View {
    let section: DailyBriefSections.Section
    let endTimes: [String: Date]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: Runner.Spacing.small) {
                RunnerSectionLabel(section.title)
                RunnerCard {
                    ForEach(section.blocks.indices, id: \.self) { index in
                        if index > 0 { RunnerHairline() }
                        let block = section.blocks[index]
                        BriefBlockView(
                            block: block,
                            ended: section.title == "Calendar"
                                && endTimes[block.text].map { $0 <= context.date } == true
                        )
                        .runnerCardRow()
                    }
                }
            }
        }
    }
}

struct BriefBlockView: View {
    let block: BriefMarkdown.Block
    var ended = false

    var body: some View {
        switch block {
        case .heading(let text):
            Text(text)
                .font(Runner.Typography.bodySemibold)
                .foregroundStyle(Runner.Palette.foreground)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let text), .paragraph(let text):
            Text(BriefMarkdown.inline(ended ? text.replacingOccurrences(of: "**", with: "") : text))
                .font(Runner.Typography.body)
                .foregroundStyle(ended ? Runner.Palette.mutedForeground : Runner.Palette.foreground)
                .tint(ended ? Runner.Palette.mutedForeground : Runner.Palette.accent)
                .accessibilityValue(ended ? "Ended" : "")
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

        var text: String {
            switch self {
            case .heading(let text), .bullet(let text), .paragraph(let text): text
            }
        }
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
            } else if line.hasPrefix("#") {
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
        HStack(alignment: .center, spacing: Runner.Spacing.tight) {
            VStack(alignment: .leading, spacing: Runner.Spacing.xxsmall) {
                Text(brief.title)
                    .font(Runner.Typography.smallMedium)
                    .foregroundStyle(Runner.Palette.foreground)
                    .lineLimit(1)

                if let summary = brief.summary, !summary.isEmpty {
                    Text(summary)
                        .font(Runner.Typography.caption)
                        .foregroundStyle(Runner.Palette.mutedForeground)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: Runner.Spacing.small)

            if let date = brief.referenceDate {
                Text(MorningBriefingCopy.dayLabel(for: date))
                    .font(Runner.Typography.caption)
                    .foregroundStyle(Runner.Palette.mutedForeground)
            }

            Image(systemName: "chevron.right")
                .font(Runner.Typography.caption)
                .foregroundStyle(Runner.Palette.mutedForeground)
                .accessibilityHidden(true)
        }
        .runnerCardRow()
        .contentShape(Rectangle())
    }
}

enum MorningBriefingCopy {
    static let sectionTitle = "Morning briefing"
    static let navigationTitle = "Briefing"
    static let readBriefingTitle = "Read the briefing"
    static let previousSectionTitle = "Previous briefings"

    private static let dayLabelStyle: Date.FormatStyle = .dateTime.weekday(.wide).month(.abbreviated).day()

    static func dayLabel(for date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(dayLabelStyle)
    }
}
