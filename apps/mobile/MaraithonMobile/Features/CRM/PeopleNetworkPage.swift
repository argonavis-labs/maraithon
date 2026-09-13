import SwiftUI
import PeopleNetworkKit

/// People page: list-first rows sorted by affinity with search and sort, a
/// network graph tab, and a pushed person page. Ranking stays server-side;
/// this page only reads the bounded projection and refreshes while active.
struct PeopleNetworkPage: View {
    enum Tab: Hashable {
        case list
        case graph
    }

    let loadNetwork: PeopleNetworkPageStore.Loader
    let loadPerson: PeopleNetworkPageStore.DetailLoader
    @Binding var path: [String]
    let openTodo: (String) -> Void
    let managePerson: (String?) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var store = PeopleNetworkPageStore()
    @State private var tab: Tab = .list
    @State private var days = 30
    @State private var query = ""
    @State private var sort: PeopleNetworkCopy.Sort = .affinity

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                RunnerPageHeader(
                    eyebrow: "Your workspace",
                    title: "People",
                    count: store.network?.peopleCount,
                    subtitle: "The people behind your work, ranked by how much you actually talk."
                ) {
                    HStack(spacing: Runner.Spacing.small) {
                        Button {
                            managePerson(nil)
                        } label: {
                            Label("Manage", systemImage: "person.crop.circle")
                        }
                        .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
                        .accessibilityLabel("Manage people")

                        Button {
                            Task { await refresh() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
                        .disabled(store.loading)
                    }
                }
                .padding(.horizontal, Runner.Layout.pageInset)

                RunnerTabs(
                    items: [
                        RunnerTabs<Tab>.Item(id: .list, title: "People"),
                        RunnerTabs<Tab>.Item(id: .graph, title: "Network graph")
                    ],
                    selection: $tab
                )

                filters
                content
            }
            .padding(.top, Runner.Spacing.small)
            .padding(.bottom, Runner.Spacing.xlarge)
        }
        .refreshable { await refresh() }
        .runnerPage()
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: String.self) { id in
            PeopleNetworkPersonPage(
                personID: id,
                days: days,
                loadPerson: loadPerson,
                select: select,
                openTodo: openTodo,
                managePerson: managePerson
            )
        }
        .task(id: requestKey) {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await refresh()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                await refresh()
            }
        }
        .onChange(of: path) { _, newPath in
            store.selectedID = newPath.last
        }
    }

    // MARK: - Filters

    private var filters: some View {
        VStack(alignment: .leading, spacing: Runner.Spacing.snug) {
            RunnerSearchField(
                placeholder: "Search by name, email, company, or note",
                text: $query,
                onSubmit: { Task { await refresh() } }
            )
            .accessibilityLabel("Find a person")

            HStack(alignment: .center, spacing: Runner.Spacing.small) {
                Text(controlHint)
                    .font(Runner.Typography.caption)
                    .foregroundStyle(Runner.Palette.mutedForeground)
                    .lineLimit(1)
                Spacer(minLength: Runner.Spacing.small)
                if tab == .list {
                    PeopleMenuControl(label: "Sort", value: sort.title) {
                        Picker("Sort", selection: $sort) {
                            ForEach(PeopleNetworkCopy.Sort.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    }
                } else {
                    PeopleMenuControl(label: "History", value: PeopleNetworkCopy.historyLabel(days)) {
                        Picker("History", selection: $days) {
                            ForEach(PeopleNetworkCopy.historyOptions, id: \.self) { option in
                                Text(PeopleNetworkCopy.historyLabel(option)).tag(option)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Runner.Layout.pageInset)
        .padding(.vertical, Runner.Spacing.medium)
    }

    private var controlHint: String {
        guard let network = store.network, network.status == "ready" else { return "" }
        if tab == .list {
            return PeopleNetworkCopy.summary(visible: network.nodes.count, known: network.peopleCount, query: query)
        }
        return PeopleNetworkCopy.footer(visible: network.nodes.count, known: network.peopleCount)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let network = store.network, network.status == "ready" {
            if let error = store.error {
                noticeRow(error)
            }
            switch tab {
            case .list:
                listTab(network)
            case .graph:
                PeopleNetworkGraphTab(
                    network: network,
                    selectedID: store.selectedID,
                    connection: store.connection,
                    select: select,
                    inspect: inspect,
                    clearConnection: { store.connection = nil }
                )
                .padding(.horizontal, Runner.Layout.pageInset)
                footer(network)
            }
        } else if store.loading, store.network == nil {
            RunnerEmptyState(title: "Loading your network…", description: "Ranking who you talk to most.")
        } else if let error = store.error {
            RunnerEmptyState(
                title: "Your network couldn’t load.",
                description: error,
                actionTitle: "Try again"
            ) {
                Task { await refresh() }
            }
        } else {
            RunnerEmptyState(
                title: "Your network is being prepared",
                description: "The list appears after the first background update."
            )
        }
    }

    private func listTab(_ network: PeopleNetworkData.Network) -> some View {
        let people = sort.apply(network.nodes)
        return VStack(alignment: .leading, spacing: 0) {
            if people.isEmpty {
                RunnerEmptyState(
                    title: PeopleNetworkCopy.emptyTitle(query: query),
                    description: PeopleNetworkCopy.emptyDescription(query: query)
                )
            } else {
                RunnerHairline()
                    .padding(.horizontal, Runner.Layout.pageInset)
                LazyVStack(spacing: 0) {
                    ForEach(people) { person in
                        NavigationLink(value: person.id) {
                            PeopleNetworkRow(person: person)
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .bottom) { RunnerHairline() }
                    }
                }
                .padding(.horizontal, Runner.Layout.pageInset)
                footer(network)
            }
        }
    }

    private func footer(_ network: PeopleNetworkData.Network) -> some View {
        let summary = Text(PeopleNetworkCopy.footer(visible: network.nodes.count, known: network.peopleCount))
        let updated = Text(PeopleNetworkCopy.updatedLabel(network.refreshedAt) ?? "")
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Runner.Spacing.small) {
                summary
                Spacer(minLength: Runner.Spacing.small)
                updated
            }
            VStack(alignment: .leading, spacing: Runner.Spacing.xxsmall) {
                summary
                updated
            }
        }
        .font(Runner.Typography.caption)
        .foregroundStyle(Runner.Palette.mutedForeground)
        .padding(.horizontal, Runner.Layout.pageInset)
        .padding(.top, Runner.Spacing.tight)
    }

    private func noticeRow(_ message: String) -> some View {
        HStack(spacing: Runner.Spacing.small) {
            Image(systemName: "exclamationmark.triangle")
                .font(Runner.Typography.caption)
                .foregroundStyle(Runner.Palette.cautionText)
                .accessibilityHidden(true)
            Text(message)
                .font(Runner.Typography.small)
                .foregroundStyle(Runner.Palette.cautionText)
                .lineLimit(2)
            Spacer(minLength: Runner.Spacing.small)
            Button("Retry") { Task { await refresh() } }
                .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
        }
        .padding(.horizontal, Runner.Layout.pageInset)
        .padding(.bottom, Runner.Spacing.medium)
    }

    // MARK: - Actions

    private var requestKey: String { "\(days):\(query):\(store.selectedID ?? "")" }

    private func select(_ id: String) {
        store.connection = nil
        path.append(id)
    }

    private func inspect(_ edge: PeopleNetworkData.Edge) {
        store.connection = edge
    }

    private func refresh() async {
        await store.load(days: days, query: query, loader: loadNetwork)
    }
}

/// Hairline menu button showing "Label  Value" with a chevron; the menu
/// content is a picker so the current choice carries a checkmark.
struct PeopleMenuControl<Options: View>: View {
    let label: String
    let value: String
    @ViewBuilder let options: () -> Options

    var body: some View {
        Menu {
            options()
        } label: {
            HStack(spacing: Runner.Spacing.xsmall) {
                Text(label)
                    .font(Runner.Typography.small)
                    .foregroundStyle(Runner.Palette.mutedForeground)
                Text(value)
                    .font(Runner.Typography.smallMedium)
                    .foregroundStyle(Runner.Palette.foreground)
                Image(systemName: "chevron.down")
                    .font(Runner.Typography.micro)
                    .foregroundStyle(Runner.Palette.mutedForeground)
                    .accessibilityHidden(true)
            }
            .lineLimit(1)
            .padding(.horizontal, Runner.Spacing.snug)
            .frame(minHeight: Runner.Layout.compactControlHeight)
            .background(Runner.Palette.background, in: RoundedRectangle(cornerRadius: Runner.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Runner.Radius.control, style: .continuous)
                    .stroke(Runner.Palette.border, lineWidth: Runner.Stroke.hairline)
            }
            .contentShape(RoundedRectangle(cornerRadius: Runner.Radius.control, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("\(label), \(value)")
    }
}
