import SwiftUI
import PeopleNetworkKit

/// Person page: header with avatar and relationship facts, open work,
/// meetings, and recent history on the left, relationship details, notes,
/// and shared context on the right. Mirrors the web person page.
struct PersonDetailView: View {
    let store: PeopleStore
    let days: Int
    let back: () -> Void
    let select: (String) -> Void
    let openTodo: (String) -> Void
    let managePerson: (String?) -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.large) {
            Button(action: back) {
                HStack(spacing: Tokens.Spacing.xsmall) {
                    Image(systemName: "chevron.left").font(Tokens.Typography.caption)
                    Text("People")
                }
            }
            .buttonStyle(RunnerButtonStyle(.plain))
            .keyboardShortcut(.escape, modifiers: [])

            if store.loadingPerson {
                Text("Gathering what you have with this person…")
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.mutedForeground)
            } else if let person = store.person {
                header(person)
                Rectangle().fill(Tokens.Palette.border).frame(height: Tokens.Stroke.hairline)
                HStack(alignment: .top, spacing: Tokens.Spacing.large) {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.large) {
                        openWork(person)
                        meetings(person)
                        history(person)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: Tokens.Spacing.large) {
                        relationship(person)
                        notes(person)
                        sharedContext(person)
                    }
                    .frame(width: Tokens.PeopleLayout.asideWidth, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
                    Text(store.detailError ?? "This person is no longer in the current network.")
                        .font(Tokens.Typography.body)
                        .foregroundStyle(Tokens.Palette.mutedForeground)
                    Button("Try again", action: retry)
                        .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
                }
            }
        }
    }

    private func header(_ person: PeopleNetworkData.Person) -> some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.medium) {
            PersonAvatar(initials: person.initials, size: Tokens.PeopleLayout.detailAvatarSize)
            VStack(alignment: .leading, spacing: Tokens.Spacing.xsmall) {
                Text(person.name)
                    .font(Tokens.Typography.pageTitle)
                    .tracking(Tokens.Typography.pageTitleTracking)
                    .foregroundStyle(Tokens.Palette.foreground)
                if let subtitle = person.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Tokens.Typography.body)
                        .foregroundStyle(Tokens.Palette.foreground80)
                }
                Text(metaLine(person))
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.mutedForeground)
            }
            Spacer(minLength: Tokens.Spacing.medium)
            Button("Manage person") { managePerson(person.personID) }
                .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
        }
        .padding(.bottom, Tokens.Spacing.xsmall)
    }

    private func metaLine(_ person: PeopleNetworkData.Person) -> String {
        var parts: [String] = []
        let channels = PeopleCopy.channels(person)
        if !channels.isEmpty { parts.append(channels) }
        parts.append("\(person.activeDays) active days")
        parts.append("\(person.messageCount) messages")
        parts.append("Last \(days) days")
        return parts.joined(separator: " · ")
    }

    private func openWork(_ person: PeopleNetworkData.Person) -> some View {
        PeopleSection(title: "Open work") {
            if person.todos?.isEmpty != false {
                PeopleEmptyRow(text: "Nothing open with \(person.name.split(separator: " ").first.map(String.init) ?? person.name).")
            }
            ForEach(person.todos ?? []) { todo in
                Button { openTodo(todo.id) } label: {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xxsmall) {
                        Text(todo.title).font(Tokens.Typography.bodyMedium).foregroundStyle(Tokens.Palette.foreground)
                        if let action = todo.nextAction, !action.isEmpty {
                            Text(action).font(Tokens.Typography.small).foregroundStyle(Tokens.Palette.mutedForeground).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .peopleRow()
            }
        }
    }

    private func meetings(_ person: PeopleNetworkData.Person) -> some View {
        PeopleSection(title: "Meetings") {
            if person.nextMeetings?.isEmpty != false {
                PeopleEmptyRow(text: "No upcoming meeting on your calendars.")
            }
            ForEach(person.nextMeetings ?? []) { meeting in
                HStack {
                    Text(meeting.title ?? "Calendar event").font(Tokens.Typography.body).foregroundStyle(Tokens.Palette.foreground)
                    Spacer()
                    Text(PeopleCopy.absoluteContact(meeting.at)).font(Tokens.Typography.caption).foregroundStyle(Tokens.Palette.mutedForeground)
                }
                .peopleRow()
            }
        }
    }

    private func history(_ person: PeopleNetworkData.Person) -> some View {
        PeopleSection(title: "Recent history") {
            if person.history?.isEmpty != false {
                PeopleEmptyRow(text: "No exchanges in the last \(days) days.")
            }
            ForEach(person.history ?? []) { event in
                PersonEvidenceRow(event: event).peopleRow()
            }
        }
    }

    private func relationship(_ person: PeopleNetworkData.Person) -> some View {
        PeopleSection(title: "Relationship") {
            PeopleFactRow(label: "Affinity", value: PeopleCopy.rankLabel(person.rank))
            PeopleFactRow(label: "Last contact", value: PeopleCopy.lastContact(person.lastAt))
            PeopleFactRow(label: "Interactions", value: "\(person.messageCount)")
            PeopleFactRow(label: "Active days (\(days)d)", value: "\(person.activeDays)")
            PeopleFactRow(label: "Channels", value: PeopleCopy.channels(person).isEmpty ? "None yet" : PeopleCopy.channels(person))
        }
    }

    @ViewBuilder
    private func notes(_ person: PeopleNetworkData.Person) -> some View {
        if let notes = person.notes, !notes.isEmpty {
            PeopleSection(title: "Notes") {
                Text(notes)
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.foreground)
                    .textSelection(.enabled)
                    .peopleRow()
            }
        }
    }

    @ViewBuilder
    private func sharedContext(_ person: PeopleNetworkData.Person) -> some View {
        if let connections = person.connections, !connections.isEmpty {
            PeopleSection(title: "Shared context with") {
                ForEach(connections.prefix(8)) { connection in
                    Button { select(connection.nodeID) } label: {
                        HStack {
                            Text(connection.name).font(Tokens.Typography.body).foregroundStyle(Tokens.Palette.foreground)
                            Spacer()
                            Text("\(connection.evidence.count)").font(Tokens.Typography.caption).foregroundStyle(Tokens.Palette.mutedForeground)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .peopleRow()
                }
            }
        }
    }
}

/// Section heading plus a hairline card holding the rows.
struct PeopleSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            Text(title)
                .font(Tokens.Typography.bodySemibold)
                .foregroundStyle(Tokens.Palette.foreground)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: Tokens.CornerRadius.small)
                    .stroke(Tokens.Palette.border, lineWidth: Tokens.Stroke.hairline)
            )
        }
    }
}

struct PeopleEmptyRow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Tokens.Typography.small)
            .foregroundStyle(Tokens.Palette.mutedForeground)
            .peopleRow()
    }
}

struct PeopleFactRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .top) {
            Text(label).font(Tokens.Typography.small).foregroundStyle(Tokens.Palette.mutedForeground)
            Spacer(minLength: Tokens.Spacing.small)
            Text(value).font(Tokens.Typography.small.monospacedDigit()).foregroundStyle(Tokens.Palette.foreground).multilineTextAlignment(.trailing)
        }
        .peopleRow()
    }
}

struct PersonEvidenceRow: View {
    let event: PeopleNetworkData.Evidence
    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxsmall) {
            HStack(alignment: .firstTextBaseline) {
                Text(event.title ?? "\(PeopleCopy.channelName(event.source)) exchange")
                    .font(Tokens.Typography.bodyMedium)
                    .foregroundStyle(Tokens.Palette.foreground)
                    .lineLimit(2)
                Spacer(minLength: Tokens.Spacing.small)
                Text(PeopleCopy.absoluteContact(event.at))
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.mutedForeground)
            }
            Text(PeopleCopy.channelName(event.source) + (event.kind == "calendar" || event.type == "calendar" ? " · On your calendar" : ""))
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.mutedForeground)
            if let excerpt = event.excerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(Tokens.Typography.small)
                    .foregroundStyle(Tokens.Palette.foreground80)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct PeopleRowChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Tokens.Spacing.medium)
            .padding(.vertical, Tokens.Spacing.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) {
                Rectangle().fill(Tokens.Palette.border).frame(height: Tokens.Stroke.hairline)
            }
    }
}

extension View {
    /// Card row: 16pt horizontal, 10pt vertical, hairline above.
    func peopleRow() -> some View { modifier(PeopleRowChrome()) }
}
