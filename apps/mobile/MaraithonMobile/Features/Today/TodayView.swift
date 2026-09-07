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

    var body: some View {
        NavigationStack {
            List {
                if let refreshErrorMessage {
                    SyncIssueBanner(
                        title: "Brief could not refresh",
                        message: refreshErrorMessage,
                        retry: { Task { await refresh() } },
                        dismiss: { self.refreshErrorMessage = nil }
                    )
                    .listRowInsets(EdgeInsets())
                }

                Section {
                    if let brief = todayBrief {
                        VStack(alignment: .leading, spacing: 8) {
                            if let summary = brief.summary, !summary.isEmpty {
                                Text(summary)
                            } else {
                                Text(brief.title)
                            }
                            if let updated = brief.insertedAt {
                                Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } else if isRefreshing && briefs.isEmpty {
                        ProgressView("Loading your day")
                    } else {
                        Text("Today's brief isn't ready yet.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(now.formatted(Date.FormatStyle(date: .complete, time: .omitted, timeZone: calendar.timeZone)))
                } footer: {
                    if let schedule {
                        Text(schedule.configured ? schedule.refreshDescription : "Morning briefing is not configured.")
                    }
                }

                if let brief = todayBrief {
                    let sections = DailyBriefSections.sections(from: brief.body ?? "", title: brief.title)
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.blocks.indices, id: \.self) { index in
                                BriefBlockView(block: section.blocks[index])
                            }
                        }
                    }
                    if !sections.contains(where: { $0.title == "Calendar" }) {
                        Section("Calendar") {
                            Text("Calendar details aren't available in this brief.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !previousBriefs.isEmpty {
                    Section("Previous briefings") {
                        ForEach(previousBriefs) { brief in
                            NavigationLink {
                                BriefDetailView(brief: brief)
                            } label: {
                                PreviousBriefRow(brief: brief)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Today")
            .listSectionSpacing(16)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AccountMenuButton() }
            }
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
