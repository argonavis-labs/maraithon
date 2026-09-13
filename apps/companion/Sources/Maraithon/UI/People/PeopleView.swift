/// People page: list-first rows sorted by affinity with search and sort, a
/// network graph tab, and an inline person page. Reads use the paired-device
/// credential and ranking stays server-side; no ingestion work runs here.
import SwiftUI
import PeopleNetworkKit

struct PeopleView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    let openTodo: (String) -> Void

    private enum Tab: Hashable {
        case list
        case graph
    }

    @State private var store = PeopleStore()
    @State private var tab: Tab = .list
    @State private var days = 30
    @State private var query = ""
    @State private var sort: PeopleCopy.Sort = .affinity
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if store.selectedID != nil {
                    PersonDetailView(
                        store: store,
                        days: days,
                        back: closePerson,
                        select: select,
                        openTodo: openTodo,
                        managePerson: managePerson,
                        retry: { Task { await store.detail(days: days, loader: personLoader) } }
                    )
                } else {
                    header
                    RunnerTabs(
                        items: [.init(id: .list, title: "People"), .init(id: .graph, title: "Network graph")],
                        selection: $tab
                    )
                    filters
                    content
                }
            }
            .frame(maxWidth: Tokens.Layout.pageMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Tokens.Spacing.page)
            .padding(.top, Tokens.Layout.pageTopInset)
            .padding(.bottom, Tokens.Spacing.page)
        }
        .background(Tokens.Palette.background)
        .task(id: requestKey) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await refresh()
        }
        .task(id: "\(days):\(store.selectedID ?? "")") {
            await store.detail(days: days, loader: personLoader)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Tokens.Spacing.medium) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Your workspace")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.mutedForeground)
                    .padding(.bottom, Tokens.Spacing.small + 1)
                HStack(alignment: .center, spacing: Tokens.Spacing.tight) {
                    Text("People")
                        .font(Tokens.Typography.pageTitle)
                        .tracking(Tokens.Typography.pageTitleTracking)
                        .foregroundStyle(Tokens.Palette.foreground)
                        .accessibilityAddTraits(.isHeader)
                    if let count = store.network?.peopleCount {
                        Text("\(count)")
                            .font(Tokens.Typography.small)
                            .foregroundStyle(Tokens.Palette.mutedForeground)
                            .padding(.horizontal, Tokens.Spacing.compact)
                            .padding(.vertical, Tokens.Spacing.xxsmall + 1)
                            .background(Tokens.Palette.foreground3, in: RoundedRectangle(cornerRadius: Tokens.CornerRadius.control))
                            .overlay {
                                RoundedRectangle(cornerRadius: Tokens.CornerRadius.control)
                                    .stroke(Tokens.Palette.border, lineWidth: Tokens.Stroke.hairline)
                            }
                            .contentTransition(.numericText())
                    }
                }
                Text("The people behind your work, ranked by how much you actually talk.")
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.mutedForeground)
                    .padding(.top, Tokens.Spacing.snug)
            }
            Spacer(minLength: Tokens.Spacing.medium)
            HStack(spacing: Tokens.Spacing.small) {
                if store.loading {
                    ProgressView().controlSize(.small).accessibilityLabel("Refreshing people")
                }
                Button("Manage people") { managePerson(nil) }
                    .buttonStyle(RunnerButtonStyle(.secondary))
                Button {
                    Task { await refresh() }
                } label: {
                    HStack(spacing: Tokens.Spacing.compact) {
                        Image(systemName: "arrow.clockwise").accessibilityHidden(true)
                        Text("Refresh")
                    }
                }
                .buttonStyle(RunnerButtonStyle(.secondary))
                .disabled(store.loading)
            }
        }
        .padding(.bottom, Tokens.Spacing.roomy)
    }

    private var filters: some View {
        HStack(spacing: Tokens.Spacing.medium) {
            RunnerSearchField(
                placeholder: "Search by name, email, company, or note",
                text: $query,
                focused: $searchFocused,
                onSubmit: { Task { await refresh() } },
                onClear: { query = "" }
            )
            .frame(maxWidth: Tokens.Layout.searchFieldMaxWidth)
            .accessibilityLabel("Find a person")
            Spacer(minLength: Tokens.Spacing.medium)
            if tab == .list {
                RunnerMenuButton(
                    label: "Sort",
                    value: sort.title,
                    options: PeopleCopy.Sort.allCases.map { option in
                        .init(id: option.rawValue, title: option.title) { sort = option }
                    }
                )
            } else {
                RunnerMenuButton(
                    label: "History",
                    value: PeopleCopy.historyLabel(days),
                    options: PeopleCopy.historyOptions.map { option in
                        .init(id: String(option), title: PeopleCopy.historyLabel(option)) { days = option }
                    }
                )
            }
        }
        .padding(.vertical, Tokens.Spacing.medium)
    }

    @ViewBuilder
    private var content: some View {
        if let network = store.network, network.status == "ready" {
            if let error = store.error {
                noticeRow(error)
            }
            if tab == .list {
                listTab(network)
            } else {
                PeopleGraphTab(store: store, network: network, select: select, inspect: inspect) {
                    store.connection = nil
                }
                footer(network)
            }
        } else if store.loading, store.network == nil {
            TodosEmptyView(title: "Loading your network…", description: "Ranking who you talk to most.")
        } else if let error = store.error {
            TodosEmptyView(title: "Your network couldn’t load.", description: error, actionTitle: "Try again") {
                Task { await refresh() }
            }
        } else {
            TodosEmptyView(
                title: "Your network is being prepared",
                description: "The list appears after the first background update."
            )
        }
    }

    private func listTab(_ network: PeopleNetworkData.Network) -> some View {
        let people = sort.apply(network.nodes)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(PeopleCopy.summary(visible: people.count, known: network.peopleCount, query: query))
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.mutedForeground)
                Spacer()
                Text(sort.footerLabel)
                    .font(Tokens.Typography.micro)
                    .foregroundStyle(Tokens.Palette.mutedForeground)
            }
            .padding(.bottom, Tokens.Spacing.snug)
            PeopleTableHeader()
            if people.isEmpty {
                TodosEmptyView(title: PeopleCopy.emptyTitle(query: query), description: PeopleCopy.emptyDescription(query: query))
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(people) { person in
                        PersonRow(person: person) { select(person.id) }
                    }
                }
                footer(network)
            }
        }
    }

    private func footer(_ network: PeopleNetworkData.Network) -> some View {
        HStack {
            Text("\(network.nodes.count) people in view · \(network.peopleCount) known people")
            Spacer()
            if let updated = PeopleCopy.updatedLabel(network.refreshedAt) {
                Text(updated)
            }
        }
        .font(Tokens.Typography.caption)
        .foregroundStyle(Tokens.Palette.mutedForeground)
        .padding(.top, Tokens.Spacing.tight)
    }

    private func noticeRow(_ message: String) -> some View {
        HStack(spacing: Tokens.Spacing.small) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Tokens.Palette.cautionText)
                .accessibilityHidden(true)
            Text(message)
                .font(Tokens.Typography.small)
                .foregroundStyle(Tokens.Palette.cautionText)
                .lineLimit(2)
            Spacer()
            Button("Retry") { Task { await refresh() } }
                .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
        }
        .padding(.horizontal, Tokens.Spacing.tight)
        .padding(.bottom, Tokens.Spacing.medium)
    }

    private var requestKey: String { "\(days):\(query):\(store.selectedID ?? "")" }

    private func select(_ id: String) {
        store.connection = nil
        store.selectedID = id
    }

    private func inspect(_ edge: PeopleNetworkData.Edge) {
        store.connection = edge
    }

    private func closePerson() {
        store.selectedID = nil
        store.person = nil
        store.detailError = nil
    }

    private func refresh() async {
        await store.load(days: days, query: query, loader: networkLoader)
    }

    private var networkLoader: PeopleStore.Loader {
        let auth = env.deviceAuth
        let log = env.eventLog
        let client = MaraithonClient(tokenProvider: { await auth.currentToken })
        return { days, query, focus in
            do {
                return try await client.peopleNetwork(days: days, query: query, focus: focus)
            } catch MaraithonClientError.unauthorized {
                await auth.tokenRejected()
                throw MaraithonClientError.unauthorized
            } catch {
                await log.warning("people.read_failed", source: .cloud)
                throw error
            }
        }
    }

    private var personLoader: PeopleStore.DetailLoader {
        let auth = env.deviceAuth
        let client = MaraithonClient(tokenProvider: { await auth.currentToken })
        return { days, id in
            do {
                return try await client.networkPerson(days: days, id: id)
            } catch MaraithonClientError.unauthorized {
                await auth.tokenRejected()
                throw MaraithonClientError.unauthorized
            }
        }
    }

    private func managePerson(_ id: String?) {
        var components = URLComponents(url: MaraithonClient.defaultBaseURL, resolvingAgainstBaseURL: false)
        components?.path = "/operator/people/manage"
        components?.queryItems = id.map { [URLQueryItem(name: "person_id", value: $0)] }
        if let url = components?.url { openURL(url) }
    }
}
