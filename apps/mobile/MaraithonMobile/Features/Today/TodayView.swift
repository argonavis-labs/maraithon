import SwiftUI

struct TodayView: View {
    @Environment(AppNavigation.self) private var appNavigation
    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var briefs: [MobileAPIClient.RemoteBrief] = []
    @State private var schedule: MobileAPIClient.MorningSchedule?
    @State private var refreshErrorMessage: String?
    @State private var isRefreshing = false
    @State private var now = Date()

    private var calendar: Calendar {
        var calendar = Calendar.current
        if let name = schedule?.timezone, let timezone = TimeZone(identifier: name) {
            calendar.timeZone = timezone
        }
        return calendar
    }

    private var todayBrief: MobileAPIClient.RemoteBrief? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: now)
        return briefs.first { brief in
            if let localDate = brief.localDate { return localDate == day }
            guard let date = brief.referenceDate else { return false }
            return calendar.isDate(date, inSameDayAs: now)
        }
    }

    private var previousBriefs: [MobileAPIClient.RemoteBrief] {
        briefs.filter { $0.id != todayBrief?.id }
    }

    private var isVisible: Bool {
        scenePhase == .active && appNavigation.selectedTab == .today
    }

    private var dateEyebrow: String {
        now.formatted(Date.FormatStyle(date: .complete, time: .omitted, timeZone: calendar.timeZone))
    }

    private var scheduleSubtitle: String? {
        guard let schedule else { return nil }
        return schedule.configured ? schedule.refreshDescription : "Morning briefing is not configured."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let refreshErrorMessage {
                        SyncIssueBanner(
                            title: "Brief could not refresh",
                            message: refreshErrorMessage,
                            retry: { Task { await refresh() } },
                            dismiss: { self.refreshErrorMessage = nil }
                        )
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        RunnerPageHeader(eyebrow: dateEyebrow, title: "Today", subtitle: scheduleSubtitle) {
                            AccountMenuButton()
                        }

                        VStack(alignment: .leading, spacing: Runner.Spacing.large) {
                            todayBriefCard

                            if let brief = todayBrief {
                                briefSections(for: brief)
                            }

                            if !previousBriefs.isEmpty {
                                previousBriefList
                            }
                        }
                    }
                    .padding(.horizontal, Runner.Layout.pageInset)
                    .padding(.top, Runner.Spacing.small)
                    .padding(.bottom, Runner.Spacing.xlarge)
                }
            }
            .runnerPage()
            .toolbar(.hidden, for: .navigationBar)
            .task(id: isVisible) {
                guard isVisible else { return }
                // The server creates the daily brief even when the app is closed.
                // Recheck while visible so a new morning arrives without a relaunch.
                while !Task.isCancelled {
                    await refresh()
                    do {
                        try await Task.sleep(for: .seconds(todayBrief == nil ? 60 : 300))
                    } catch { break }
                }
            }
            .refreshable { await refresh() }
        }
    }

    private var todayBriefCard: some View {
        RunnerCard {
            Group {
                if let brief = todayBrief {
                    VStack(alignment: .leading, spacing: Runner.Spacing.small) {
                        Group {
                            if let summary = brief.summary, !summary.isEmpty {
                                Text(summary)
                            } else {
                                Text(brief.title)
                            }
                        }
                        .font(Runner.Typography.body)
                        .foregroundStyle(Runner.Palette.foreground)
                        .fixedSize(horizontal: false, vertical: true)

                        if let updated = brief.insertedAt {
                            Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                                .font(Runner.Typography.caption)
                                .foregroundStyle(Runner.Palette.mutedForeground)
                        }
                    }
                } else if isRefreshing && briefs.isEmpty {
                    HStack(spacing: Runner.Spacing.snug) {
                        ProgressView()
                            .tint(Runner.Palette.mutedForeground)
                        Text("Loading your day")
                            .font(Runner.Typography.small)
                            .foregroundStyle(Runner.Palette.mutedForeground)
                    }
                } else {
                    Text("Today's brief isn't ready yet.")
                        .font(Runner.Typography.small)
                        .foregroundStyle(Runner.Palette.mutedForeground)
                }
            }
            .padding(Runner.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func briefSections(for brief: MobileAPIClient.RemoteBrief) -> some View {
        let sections = DailyBriefSections.sections(from: brief.body ?? "", title: brief.title)

        ForEach(sections) { section in
            VStack(alignment: .leading, spacing: Runner.Spacing.small) {
                RunnerSectionLabel(section.title)
                RunnerCard {
                    ForEach(section.blocks.indices, id: \.self) { index in
                        if index > 0 { RunnerHairline() }
                        BriefBlockView(block: section.blocks[index])
                            .runnerCardRow()
                    }
                }
            }
        }

        if !sections.contains(where: { $0.title == "Calendar" }) {
            VStack(alignment: .leading, spacing: Runner.Spacing.small) {
                RunnerSectionLabel("Calendar")
                RunnerCard {
                    Text("Calendar details aren't available in this brief.")
                        .font(Runner.Typography.small)
                        .foregroundStyle(Runner.Palette.mutedForeground)
                        .runnerCardRow()
                }
            }
        }
    }

    private var previousBriefList: some View {
        VStack(alignment: .leading, spacing: Runner.Spacing.small) {
            RunnerSectionLabel(MorningBriefingCopy.previousSectionTitle)
            RunnerCard {
                ForEach(Array(previousBriefs.enumerated()), id: \.element.id) { index, brief in
                    if index > 0 { RunnerHairline() }
                    NavigationLink {
                        BriefDetailView(brief: brief)
                    } label: {
                        PreviousBriefRow(brief: brief)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func refresh() async {
        guard !isRefreshing, let token = sessionStore.user?.sessionToken else { return }
        now = Date()
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let response = try await MobileAPIClient().loadDailyBriefs(sessionToken: token)
            guard !Task.isCancelled else { return }
            briefs = response.briefs
            schedule = response.morningSchedule
            refreshErrorMessage = nil
        } catch is CancellationError {
            // Switching tabs cancels the visible-screen refresh.
        } catch {
            guard !Task.isCancelled else { return }
            refreshErrorMessage = MobileErrorCopy.message(for: error)
        }
    }
}

/// Preserve the source-backed brief's content, with native sections for scanning.
/// Older briefings use "Today's Schedule"; both shapes render as Calendar.
enum DailyBriefSections {
    struct Section: Identifiable {
        let id: Int
        let title: String
        var blocks: [BriefMarkdown.Block]
    }

    static func sections(from body: String, title: String) -> [Section] {
        var sections: [Section] = []
        var heading = "Day guide"
        var blocks: [BriefMarkdown.Block] = []
        func flush() {
            guard !blocks.isEmpty else { return }
            sections.append(Section(id: sections.count, title: heading, blocks: blocks))
            blocks = []
        }
        for block in BriefMarkdown.blocks(from: body) {
            switch block {
            case .heading(let text):
                flush()
                if text == title { continue }
                switch text.lowercased().replacingOccurrences(of: "’", with: "'") {
                case "today's schedule", "schedule", "calendar": heading = "Calendar"
                case "who you're meeting", "meeting prep": heading = "Who you're meeting"
                default: heading = text
                }
            default: blocks.append(block)
            }
        }
        flush()
        let primaryTitles = ["Calendar", "Who you're meeting"]
        return primaryTitles.flatMap { title in sections.filter { $0.title == title } }
            + sections.filter { !primaryTitles.contains($0.title) }
    }
}
