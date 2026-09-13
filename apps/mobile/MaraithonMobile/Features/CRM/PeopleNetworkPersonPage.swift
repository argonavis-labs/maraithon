import SwiftUI
import PeopleNetworkKit

/// Person page pushed from the People list: header with avatar and
/// relationship facts, then open work, meetings, recent history,
/// relationship details, notes, and shared context. Mirrors the web person page.
struct PeopleNetworkPersonPage: View {
    let personID: String
    let days: Int
    let loadPerson: PeopleNetworkPageStore.DetailLoader
    let select: (String) -> Void
    let openTodo: (String) -> Void
    let managePerson: (String?) -> Void

    @State private var person: PeopleNetworkData.Person?
    @State private var loading = false
    @State private var error: String?
    @State private var reloadToken = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Runner.Spacing.large) {
                if loading, person == nil {
                    RunnerEmptyState(
                        title: "Loading person…",
                        description: "Gathering what you have with this person."
                    )
                } else if let person {
                    header(person)
                    RunnerHairline()
                    openWork(person)
                    meetings(person)
                    history(person)
                    relationship(person)
                    notes(person)
                    sharedContext(person)
                } else {
                    RunnerEmptyState(
                        title: "Person unavailable",
                        description: error ?? "This person is no longer in the current network.",
                        actionTitle: "Try again"
                    ) {
                        reloadToken += 1
                    }
                }
            }
            .padding(.horizontal, Runner.Layout.pageInset)
            .padding(.top, Runner.Spacing.medium)
            .padding(.bottom, Runner.Spacing.xlarge)
        }
        .runnerPage()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(days):\(personID):\(reloadToken)") {
            await load()
        }
    }

    // MARK: - Sections

    private func header(_ person: PeopleNetworkData.Person) -> some View {
        VStack(alignment: .leading, spacing: Runner.Spacing.medium) {
            HStack(alignment: .top, spacing: Runner.Spacing.medium) {
                PeopleAvatar(initials: person.initials, size: PeopleAvatar.detailSize)
                VStack(alignment: .leading, spacing: Runner.Spacing.xsmall) {
                    Text(person.name)
                        .font(Runner.Typography.pageTitle)
                        .tracking(Runner.Typography.pageTitleTracking)
                        .foregroundStyle(Runner.Palette.foreground)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle = person.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(Runner.Typography.body)
                            .foregroundStyle(Runner.Palette.foreground80)
                    }
                    Text(metaLine(person))
                        .font(Runner.Typography.caption)
                        .foregroundStyle(Runner.Palette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Manage person") { managePerson(person.personID) }
                .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
        }
    }

    private func metaLine(_ person: PeopleNetworkData.Person) -> String {
        var parts: [String] = []
        let channels = PeopleNetworkCopy.channels(person)
        if !channels.isEmpty { parts.append(channels) }
        parts.append("\(person.activeDays) active days")
        parts.append("\(person.messageCount) messages")
        parts.append("Last \(days) days")
        return parts.joined(separator: " · ")
    }

    private func openWork(_ person: PeopleNetworkData.Person) -> some View {
        section("Open work") {
            let todos = person.todos ?? []
            if todos.isEmpty {
                emptyRow("Nothing open with \(PeopleNetworkCopy.firstName(person.name)).")
            }
            ForEach(Array(todos.enumerated()), id: \.element.id) { index, todo in
                if index > 0 { RunnerHairline() }
                Button {
                    openTodo(todo.id)
                } label: {
                    VStack(alignment: .leading, spacing: Runner.Spacing.xxsmall) {
                        Text(todo.title)
                            .font(Runner.Typography.bodyMedium)
                            .foregroundStyle(Runner.Palette.foreground)
                        if let action = todo.nextAction, !action.isEmpty {
                            Text(action)
                                .font(Runner.Typography.small)
                                .foregroundStyle(Runner.Palette.mutedForeground)
                                .lineLimit(2)
                        }
                    }
                    .runnerCardRow()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens this todo")
            }
        }
    }

    private func meetings(_ person: PeopleNetworkData.Person) -> some View {
        section("Meetings") {
            let meetings = person.nextMeetings ?? []
            if meetings.isEmpty {
                emptyRow("No upcoming meeting on your calendars.")
            }
            ForEach(Array(meetings.enumerated()), id: \.element.id) { index, meeting in
                if index > 0 { RunnerHairline() }
                HStack(alignment: .firstTextBaseline, spacing: Runner.Spacing.small) {
                    Text(meeting.title ?? "Calendar event")
                        .font(Runner.Typography.body)
                        .foregroundStyle(Runner.Palette.foreground)
                        .lineLimit(2)
                    Spacer(minLength: Runner.Spacing.small)
                    Text(PeopleNetworkCopy.absoluteContact(meeting.at))
                        .font(Runner.Typography.caption)
                        .foregroundStyle(Runner.Palette.mutedForeground)
                        .multilineTextAlignment(.trailing)
                }
                .runnerCardRow()
            }
        }
    }

    private func history(_ person: PeopleNetworkData.Person) -> some View {
        section("Recent history") {
            let events = person.history ?? []
            if events.isEmpty {
                emptyRow("No exchanges in the last \(days) days.")
            }
            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                if index > 0 { RunnerHairline() }
                PeopleEvidenceRow(event: event)
                    .runnerCardRow()
            }
        }
    }

    private func relationship(_ person: PeopleNetworkData.Person) -> some View {
        let channels = PeopleNetworkCopy.channels(person)
        return section("Relationship") {
            RunnerKeyValueRow(label: "Affinity", value: PeopleNetworkCopy.rankLabel(person.rank))
            RunnerHairline()
            RunnerKeyValueRow(label: "Last contact", value: PeopleNetworkCopy.lastContact(person.lastAt))
            RunnerHairline()
            RunnerKeyValueRow(label: "Interactions", value: "\(person.messageCount)")
            RunnerHairline()
            RunnerKeyValueRow(label: "Active days (\(days)d)", value: "\(person.activeDays)")
            RunnerHairline()
            RunnerKeyValueRow(label: "Channels", value: channels.isEmpty ? "None yet" : channels)
        }
    }

    @ViewBuilder
    private func notes(_ person: PeopleNetworkData.Person) -> some View {
        if let notes = person.notes, !notes.isEmpty {
            section("Notes") {
                Text(notes)
                    .font(Runner.Typography.body)
                    .foregroundStyle(Runner.Palette.foreground)
                    .textSelection(.enabled)
                    .runnerCardRow()
            }
        }
    }

    @ViewBuilder
    private func sharedContext(_ person: PeopleNetworkData.Person) -> some View {
        if let connections = person.connections, !connections.isEmpty {
            section("Shared context with") {
                ForEach(Array(connections.prefix(8).enumerated()), id: \.element.id) { index, connection in
                    if index > 0 { RunnerHairline() }
                    Button {
                        select(connection.nodeID)
                    } label: {
                        HStack(spacing: Runner.Spacing.small) {
                            Text(connection.name)
                                .font(Runner.Typography.body)
                                .foregroundStyle(Runner.Palette.foreground)
                                .lineLimit(1)
                            Spacer(minLength: Runner.Spacing.small)
                            Text("\(connection.evidence.count)")
                                .font(Runner.Typography.caption.monospacedDigit())
                                .foregroundStyle(Runner.Palette.mutedForeground)
                            Image(systemName: "chevron.right")
                                .font(Runner.Typography.caption)
                                .foregroundStyle(Runner.Palette.mutedForeground)
                                .accessibilityHidden(true)
                        }
                        .runnerCardRow()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(connection.name), \(connection.evidence.count) shared items")
                    .accessibilityHint("Opens this person")
                }
            }
        }
    }

    // MARK: - Building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder rows: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Runner.Spacing.small) {
            RunnerSectionLabel(title)
            RunnerCard {
                rows()
            }
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(Runner.Typography.small)
            .foregroundStyle(Runner.Palette.mutedForeground)
            .runnerCardRow()
    }

    // MARK: - Loading

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let result = try await loadPerson(days, personID)
            try Task.checkCancellation()
            person = result
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            person = nil
            self.error = error.localizedDescription
        }
    }
}
