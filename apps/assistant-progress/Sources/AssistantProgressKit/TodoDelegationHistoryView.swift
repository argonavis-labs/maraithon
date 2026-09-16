import SwiftUI

/// Read-only history shared by iPhone and Mac; paging never changes conversation authority.
struct TodoDelegationHistoryView: View {
    let delegationID: String
    let request: TodoDelegationPanel.Transport
    @Environment(\.dismiss) private var dismiss
    @State private var history: TodoDelegationHistory?
    @State private var entries: [TodoDelegationHistory.Entry] = []
    @State private var before: String?
    @State private var attempt = UUID()
    @State private var busy = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let history {
                    if history.outcome != nil || !history.evidence.isEmpty {
                        Section("Outcome and evidence") {
                            if let outcome = history.outcome { Text(outcome) }
                            sourceLinks(history.evidence)
                        }
                    }
                    if !history.facts.isEmpty {
                        DisclosureGroup("Saved facts (\(history.facts.count))") {
                            ForEach(history.facts) { fact in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(fact.text)
                                    timestamp(fact.recordedAt)
                                    sourceLinks(fact.links)
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                }
                Section("Activity, newest first") {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title).font(.headline)
                            timestamp(entry.occurredAt)
                            if let detail = entry.detail { Text(detail).font(.callout) }
                            sourceLinks(entry.links)
                        }.padding(.vertical, 4)
                    }
                    if history != nil && entries.isEmpty { Text("No conversation activity yet.").foregroundStyle(.secondary) }
                    if busy { ProgressView("Loading history…") }
                    if let error { Text(error).foregroundStyle(.red) }
                    if let next = history?.nextBefore {
                        Button("Older activity") { load(before: next) }.disabled(busy)
                    }
                }
            }
            .navigationTitle("Conversation history")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { load(before: nil) }.disabled(busy)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 640)
        #endif
        .task(id: attempt) { await fetch() }
    }

    @ViewBuilder private func sourceLinks(_ links: [TodoDelegationHistory.SourceLink]) -> some View {
        ForEach(links, id: \.self) { link in
            if let url = URL(string: link.url) {
                Link(link.label, destination: url).font(.callout)
            }
        }
    }

    @ViewBuilder private func timestamp(_ value: String?) -> some View {
        if let value {
            let date = (try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
                ?? (try? Date(value, strategy: .iso8601))
            if let date { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func load(before cursor: String?) {
        before = cursor
        busy = true
        attempt = UUID()
    }

    @MainActor private func fetch() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let suffix = before.map { "?before=\($0)" } ?? ""
            guard let page = try await request("delegations/\(delegationID)/history\(suffix)", nil).history else {
                throw TodoDelegation.Failure("Conversation history couldn't load. Try refreshing it.")
            }
            try Task.checkCancellation()
            var seen = Set<String>()
            entries = ((before == nil ? [] : entries) + page.entries).filter { seen.insert($0.id).inserted }
            history = page
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}
