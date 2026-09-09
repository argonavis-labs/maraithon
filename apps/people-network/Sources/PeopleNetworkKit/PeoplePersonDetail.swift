/// Native person inspection keeps messages, calendar evidence, and open todos distinct.
import SwiftUI

struct PeoplePersonDetail: View {
    let person: PeopleNetworkData.Person
    let days: Int
    let select: (String) -> Void
    let inspect: (PeopleNetworkData.Edge) -> Void
    let openTodo: (String) -> Void
    let managePerson: (String?) -> Void

    var body: some View {
        List {
            Section {
                Text(person.name).font(.title2.weight(.semibold))
                if let subtitle = person.subtitle { Text(subtitle).foregroundStyle(.secondary) }
                Text("\(person.activeDays) active days · \(person.messageCount) messages · Last \(days) days")
                    .font(.caption).foregroundStyle(.secondary)
                Text(person.channels.map { PeopleNetworkData.sourceName($0.source) }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if let notes = person.notes, !notes.isEmpty { Text(notes) }
                Button("Manage person", systemImage: "person.crop.circle") { managePerson(person.personID) }
            }
            if let meetings = person.nextMeetings, !meetings.isEmpty {
                Section("Meeting next") {
                    ForEach(meetings) { meeting in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(meeting.title ?? "Calendar event")
                            NetworkDateLabel(value: meeting.at)
                        }
                    }
                }
            }
            Section("Open todos") {
                if person.todos?.isEmpty != false { Text("No open todos linked.").foregroundStyle(.secondary) }
                ForEach(person.todos ?? []) { todo in
                    Button { openTodo(todo.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(todo.title)
                            if let action = todo.nextAction { Text(action).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            Section("Recent history") {
                if person.history?.isEmpty != false { Text("No earlier exchanges found.").foregroundStyle(.secondary) }
                ForEach(person.history ?? []) { event in NetworkEvidenceRow(event: event) }
            }
            if let connections = person.connections, !connections.isEmpty {
                Section("Shared context") {
                    ForEach(connections) { connection in
                        HStack {
                            Button(connection.name) { select(connection.nodeID) }
                            Spacer()
                            Button("Evidence", systemImage: "text.magnifyingglass") {
                                inspect(.init(id: [person.id, connection.nodeID].sorted().joined(separator: ":"),
                                              from: person.id, to: connection.nodeID, kind: "shared",
                                              weight: 0, evidence: connection.evidence))
                            }
                        }
                    }
                }
            }
        }
    }
}

struct NetworkEvidenceRow: View {
    let event: PeopleNetworkData.Evidence
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(event.title ?? "\(PeopleNetworkData.sourceName(event.source)) exchange")
                .font(.body.weight(.medium))
            HStack {
                Text(PeopleNetworkData.sourceName(event.source))
                NetworkDateLabel(value: event.at)
            }.font(.caption).foregroundStyle(.secondary)
            if let excerpt = event.excerpt, !excerpt.isEmpty { Text(excerpt).font(.callout).textSelection(.enabled) }
            if event.kind == "calendar" || event.type == "calendar" {
                Text("On your calendar").font(.caption).foregroundStyle(.secondary)
            } else if event.kind == "shared" || event.kind == "conversation" {
                Text("Shared conversation").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct NetworkDateLabel: View {
    let value: String?
    var body: some View {
        if let date = PeopleNetworkData.date(value) {
            Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
