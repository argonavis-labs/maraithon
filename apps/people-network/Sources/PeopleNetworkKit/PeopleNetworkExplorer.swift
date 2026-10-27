/// Shared native People surface; clients supply authenticated reads and navigation.
/// All ranking is server-side and periodic refresh runs only while this view is active.
import SwiftUI

@MainActor
public struct PeopleNetworkExplorer: View {
    private let loadNetwork: PeopleNetworkStore.Loader
    private let loadPerson: PeopleNetworkStore.DetailLoader
    private let openTodo: (String) -> Void
    private let managePerson: (String?) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = PeopleNetworkStore()
    @State private var days = 30
    @State private var query = ""
    @State private var listMode = false

    public init(
        loadNetwork: @escaping @Sendable (Int, String, String?) async throws -> PeopleNetworkData.Network,
        loadPerson: @escaping @Sendable (Int, String) async throws -> PeopleNetworkData.Person,
        openTodo: @escaping (String) -> Void,
        managePerson: @escaping (String?) -> Void
    ) {
        self.loadNetwork = loadNetwork
        self.loadPerson = loadPerson
        self.openTodo = openTodo
        self.managePerson = managePerson
    }

    public var body: some View {
        content
            .navigationTitle("People")
            .searchable(text: $query, prompt: "Find a person")
            .toolbar {
                ToolbarItemGroup {
                    Picker("History", selection: $days) {
                        ForEach([30, 90, 180], id: \.self) { Text("\($0) days").tag($0) }
                    }
                    Toggle(isOn: $listMode) { Label("List", systemImage: "list.bullet") }
                    Button("Manage people", systemImage: "person.crop.circle") { managePerson(nil) }
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                        .disabled(store.loading)
                }
            }
            .task(id: requestKey) {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                await refresh()
            }
            .task(id: "\(days):\(store.selectedID ?? "")") {
                await store.detail(days: days, loader: loadPerson)
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    await refresh()
                }
            }
            #if os(iOS)
            .sheet(isPresented: inspecting) {
                NavigationStack {
                    inspection
                        .navigationTitle(store.connection == nil ? "Person" : "Connection")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { closeInspection() }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
            #else
            .inspector(isPresented: inspecting) {
                VStack(spacing: 0) {
                    HStack { Text("People details").font(.headline); Spacer(); Button("Close") { closeInspection() } }
                        .padding(16)
                    Divider()
                    inspection
                }
                .inspectorColumnWidth(min: 280, ideal: 340, max: 440)
            }
            #endif
    }

    @ViewBuilder private var content: some View {
        if let network = store.network, network.status == "ready" {
            VStack(spacing: 0) {
                if let error = store.error { errorRow(error) }
                if !listMode && !network.nodes.isEmpty {
                    PeopleGraphCanvas(network: network, selectedID: store.selectedID,
                                      select: select, inspect: inspect)
                        .frame(minHeight: 280, idealHeight: 420, maxHeight: .infinity)
                    Divider()
                }
                List {
                    if network.warnings?.contains("calendar_unavailable") == true {
                        Text("A connected calendar couldn’t update. Available synced meetings are shown.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !network.meetings.isEmpty {
                        Section("Meeting next") {
                            ForEach(network.meetings) { meeting in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(meeting.title ?? "Calendar event").font(.headline)
                                    NetworkDateLabel(value: meeting.at)
                                    ForEach(meeting.people ?? []) { attendee in
                                        Button(attendee.name) { select(attendee.id) }
                                    }
                                }
                            }
                        }
                    }
                    Section(listMode ? "People" : "In conversation") {
                        if network.nodes.isEmpty {
                            Text(query.isEmpty ? "No communication network yet." : "No people match this search.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(visiblePeople(network)) { person in
                            Button { select(person.id) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(person.name)
                                        if let subtitle = person.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    Text("\(person.activeDays) active days").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Section {
                        HStack {
                            Text("\(network.nodes.count) in view · \(network.peopleCount) known people")
                            Spacer()
                            if let date = PeopleNetworkData.date(network.refreshedAt) {
                                Text("Updated \(date, style: .relative) ago")
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
                .refreshable { await refresh() }
                .frame(maxHeight: listMode || network.nodes.isEmpty ? .infinity : 260)
            }
        } else if store.loading && store.network == nil {
            ProgressView("Loading your network…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.error {
            ContentUnavailableView {
                Label("Your network couldn’t load", systemImage: "person.2")
            } description: { Text(error) } actions: {
                Button("Try again") { Task { await refresh() } }
            }
        } else {
            ContentUnavailableView("Your network is being prepared", systemImage: "person.2",
                                   description: Text("People and conversations will appear after the first background update."))
        }
    }

    @ViewBuilder private var inspection: some View {
        if let edge = store.connection {
            List {
                Section(edge.kind == "direct" ? "Your communication" : "Observed shared context") {
                    ForEach(edge.evidence) { NetworkEvidenceRow(event: $0) }
                }
                Section("People") {
                    ForEach([edge.from, edge.to].filter { $0 != "you" }, id: \.self) { id in
                        Button(store.network?.nodes.first { $0.id == id }?.name ?? "View person") { select(id) }
                    }
                }
            }
        } else if store.loadingPerson {
            ProgressView("Loading person…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let person = store.person {
            PeoplePersonDetail(person: person, days: days, select: select, inspect: inspect,
                               openTodo: { closeInspection(); openTodo($0) },
                               managePerson: { closeInspection(); managePerson($0) })
        } else {
            ContentUnavailableView {
                Label("Person unavailable", systemImage: "person.crop.circle.badge.questionmark")
            } description: { Text(store.detailError ?? "This person is no longer in the current network.") }
            actions: { Button("Try again") { Task { await store.detail(days: days, loader: loadPerson) } } }
        }
    }

    private var requestKey: String { "\(days):\(query):\(store.selectedID ?? "")" }
    private var inspecting: Binding<Bool> {
        Binding(get: { store.selectedID != nil || store.connection != nil },
                set: { if !$0 { closeInspection() } })
    }
    private func select(_ id: String) { store.connection = nil; store.selectedID = id }
    private func inspect(_ edge: PeopleNetworkData.Edge) { store.connection = edge }
    private func closeInspection() { store.selectedID = nil; store.connection = nil }
    private func refresh() async { await store.load(days: days, query: query, loader: loadNetwork) }
    private func visiblePeople(_ network: PeopleNetworkData.Network) -> [PeopleNetworkData.Person] {
        listMode ? network.nodes : Array(network.nodes.sorted { $0.activeDays > $1.activeDays }.prefix(8))
    }
    private func errorRow(_ message: String) -> some View {
        HStack { Text(message).font(.caption); Spacer(); Button("Retry") { Task { await refresh() } } }.padding(8)
    }
}
