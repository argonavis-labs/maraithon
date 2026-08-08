import SwiftData
import SwiftUI

struct CRMView: View {
    @Environment(AppNavigation.self) private var appNavigation
    @Environment(\.modelContext) private var modelContext
    @Environment(SessionStore.self) private var sessionStore
    @Query(sort: \CRMContact.name) private var contacts: [CRMContact]
    @Query(sort: \TodoItem.updatedAt, order: .reverse) private var todos: [TodoItem]
    @State private var isAddingContact = false
    @State private var editingContact: CRMContact?
    @State private var searchText = ""
    @State private var selectedTab: PeopleFocusTab = .suggested
    @State private var refreshErrorMessage: String?
    @State private var actionErrorMessage: String?
    @State private var isRefreshing = false
    @State private var goals: [MobileAPIClient.RemoteGoal] = []
    @State private var reconnectSuggestions: [MobileAPIClient.RemoteReconnectSuggestion] = []
    @State private var peopleSnapshot: PeopleSnapshot?

    private var emptyState: PeopleEmptyState {
        selectedTab.emptyState(searchText: searchText, hasAnyPeople: !contacts.isEmpty)
    }

    /// Cheap content fingerprint over the contact and todo fields the priority
    /// engine derives from. `onChange` compares it every body pass;
    /// identity-based array equality would miss in-place edits like logging an
    /// outreach.
    private var peopleSignature: Int {
        var hasher = Hasher()
        hasher.combine(contacts.count)

        for contact in contacts {
            hasher.combine(contact.id)
            hasher.combine(contact.name)
            hasher.combine(contact.company)
            hasher.combine(contact.email)
            hasher.combine(contact.phone)
            hasher.combine(contact.statusRawValue)
            hasher.combine(contact.dealStageRawValue)
            hasher.combine(contact.notes)
            hasher.combine(contact.lastContactedAt)
            hasher.combine(contact.createdAt)
        }

        hasher.combine(todos.count)

        for todo in todos {
            hasher.combine(todo.id)
            hasher.combine(todo.title)
            hasher.combine(todo.notes)
            hasher.combine(todo.nextAction)
            hasher.combine(todo.isCompleted)
            hasher.combine(todo.dueDate)
            hasher.combine(todo.priorityRawValue)
            hasher.combine(todo.updatedAt)
            hasher.combine(todo.contact?.id)
        }

        return hasher.finalize()
    }

    private func makePeopleSnapshot() -> PeopleSnapshot {
        PeopleSnapshot(
            contacts: contacts,
            todos: todos,
            goals: goals,
            suggestions: reconnectSuggestions,
            searchText: searchText,
            tab: selectedTab
        )
    }

    private func rebuildPeopleSnapshot() {
        peopleSnapshot = makePeopleSnapshot()
    }

    var body: some View {
        let snapshot = peopleSnapshot ?? makePeopleSnapshot()
        NavigationStack {
            List {
                if let refreshErrorMessage {
                    Section {
                        SyncIssueBanner(
                            message: refreshErrorMessage,
                            retry: { Task { await refreshPriorityPeople(force: true) } },
                            dismiss: { self.refreshErrorMessage = nil }
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                    }
                }

                if let actionErrorMessage {
                    Section {
                        SyncIssueBanner(
                            title: CRMViewCopy.actionWarningTitle,
                            message: actionErrorMessage,
                            buttonTitle: nil,
                            retry: nil,
                            dismissAccessibilityLabel: CRMViewCopy.dismissActionWarningAccessibilityLabel,
                            dismiss: { self.actionErrorMessage = nil }
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                    }
                }

                Section {
                    FilterCountStrip(
                        selection: $selectedTab,
                        options: PeopleFocusTab.allCases.map { tab in
                            FilterCountOption(
                                value: tab,
                                title: tab.title,
                                count: snapshot.counts.value(for: tab),
                                tint: tab.tint
                            )
                        },
                        accessibilityNoun: "people"
                    )
                    .padding(.vertical, 8)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                }

                Section(selectedTab.sectionTitle) {
                    if snapshot.selected.isEmpty {
                        ContentUnavailableView(
                            emptyState.title,
                            systemImage: emptyState.systemImage,
                            description: Text(emptyState.description)
                        )
                    } else {
                        ForEach(snapshot.selected) { context in
                            NavigationLink {
                                ContactDetailView(contact: context.contact)
                            } label: {
                                PeopleContactRow(context: context, tab: selectedTab)
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    apply(.markActive, to: context.contact)
                                } label: {
                                    Label("Active", systemImage: "person.crop.circle.fill.badge.checkmark")
                                }
                                .tint(.green)

                                Button {
                                    apply(.logContact(Date()), to: context.contact)
                                } label: {
                                    Label(CRMViewCopy.reachedOutActionTitle, systemImage: "phone.arrow.up.right")
                                }
                                .tint(.blue)
                            }
                            .swipeActions(edge: .trailing) {
                                Button {
                                    apply(.archive, to: context.contact)
                                } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                                .tint(.gray)

                                Button {
                                    editingContact = context.contact
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("People")
            .searchable(text: $searchText, prompt: "Search people")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AccountMenuButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isAddingContact = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(CRMViewCopy.addPersonAccessibilityLabel)
                }
            }
            .sheet(isPresented: $isAddingContact) {
                ContactEditorView()
            }
            .sheet(item: $editingContact) { contact in
                ContactEditorView(contact: contact)
            }
            .task {
                rebuildPeopleSnapshot()
                await refreshPriorityPeople()
            }
            .refreshable {
                // An explicit pull is a demand for fresh data; bypass the
                // conditional (ETag) fast path.
                await refreshPriorityPeople(force: true)
            }
            .onChange(of: peopleSignature) { _, _ in
                rebuildPeopleSnapshot()
            }
            .onChange(of: searchText) { _, _ in
                rebuildPeopleSnapshot()
            }
            .onChange(of: selectedTab) { _, _ in
                rebuildPeopleSnapshot()
            }
            .onAppear(perform: applyRequestedFilterIfNeeded)
            .onChange(of: appNavigation.requestedPeopleFilter) { _, _ in
                applyRequestedFilterIfNeeded()
            }
        }
    }

    private func apply(_ action: CRMQuickAction, to contact: CRMContact) {
        let snapshot = CRMContactSnapshot(contact: contact)
        actionErrorMessage = nil
        action.apply(to: contact)
        guard saveLocalRelationshipChange(failureMessage: CRMViewCopy.localSaveFailedMessage) else {
            return
        }

        guard let sessionToken = sessionStore.user?.sessionToken else { return }

        Task { @MainActor in
            do {
                let remote = try await MobileAPIClient().updatePerson(
                    sessionToken: sessionToken,
                    id: contact.id,
                    payload: ProductionDataSync.personPayload(from: contact)
                )
                ProductionDataSync.apply(remote, to: contact)
                _ = saveLocalRelationshipChange(failureMessage: CRMViewCopy.remoteSaveFailedMessage)
            } catch {
                snapshot.restore(to: contact)
                if saveLocalRelationshipChange(failureMessage: CRMViewCopy.restoreFailedMessage) {
                    actionErrorMessage = "\(action.failurePrefix) \(MobileErrorCopy.message(for: error))"
                }
            }
        }
    }

    private func refreshPriorityPeople(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Goals and reconnect suggestions are pure network fetches, so they run
        // alongside the SwiftData syncs. The two ProductionDataSync calls mix
        // fetch + model-context merge and stay serialized.
        let sessionToken = sessionStore.user?.sessionToken
        async let fetchedGoals = Self.fetchGoals(sessionToken: sessionToken)
        async let fetchedSuggestions = Self.fetchReconnectSuggestions(sessionToken: sessionToken)

        do {
            try await ProductionDataSync.refreshPeople(
                sessionStore: sessionStore,
                modelContext: modelContext,
                force: force
            )
            refreshErrorMessage = nil
        } catch {
            refreshErrorMessage = "Could not refresh people. \(MobileErrorCopy.message(for: error))"
        }

        // Open work is useful context for People, but it is additive. Keep the
        // relationship directory usable even if the work endpoint is slow or
        // one remote work item cannot be decoded.
        try? await ProductionDataSync.refreshTodos(
            sessionStore: sessionStore,
            modelContext: modelContext,
            includeCards: false,
            force: force
        )

        goals = await fetchedGoals
        reconnectSuggestions = await fetchedSuggestions
        rebuildPeopleSnapshot()
    }

    private static func fetchGoals(sessionToken: String?) async -> [MobileAPIClient.RemoteGoal] {
        guard let sessionToken else { return [] }

        let remoteGoals = try? await MobileAPIClient().listGoals(
            sessionToken: sessionToken,
            status: "active",
            category: "all",
            limit: 100
        )
        return remoteGoals ?? []
    }

    private static func fetchReconnectSuggestions(
        sessionToken: String?
    ) async -> [MobileAPIClient.RemoteReconnectSuggestion] {
        // The reconnect surface is additive intelligence on top of the
        // directory; if it cannot load we silently fall back to the list
        // rather than blocking people management with an error banner.
        guard let sessionToken else { return [] }
        return (try? await MobileAPIClient().reconnectSuggestions(sessionToken: sessionToken)) ?? []
    }

    private func applyRequestedFilterIfNeeded() {
        guard let requestedFilter = appNavigation.requestedPeopleFilter else { return }
        selectedTab = PeopleFocusTab(requestedStatusFilter: requestedFilter)
        appNavigation.requestedPeopleFilter = nil
    }

    @discardableResult
    private func saveLocalRelationshipChange(failureMessage: String) -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            actionErrorMessage = failureMessage
            return false
        }
    }
}

/// Derived people state for the People tab, rebuilt only when the underlying
/// content, search text, or tab changes. The priority-engine graph is far too
/// expensive to rebuild several times per body pass.
private struct PeopleSnapshot {
    let contexts: [PeopleContactContext]
    let selected: [PeopleContactContext]
    let counts: PeopleFocusCounts

    init(
        contacts: [CRMContact],
        todos: [TodoItem],
        goals: [MobileAPIClient.RemoteGoal],
        suggestions: [MobileAPIClient.RemoteReconnectSuggestion],
        searchText: String,
        tab: PeopleFocusTab
    ) {
        contexts = PeoplePriorityEngine.contexts(
            contacts: contacts,
            todos: todos,
            goals: goals,
            suggestions: suggestions,
            searchText: searchText
        )
        selected = PeoplePriorityEngine.contexts(
            for: tab,
            contexts: contexts,
            suggestions: suggestions
        )
        counts = PeoplePriorityEngine.counts(from: contexts)
    }
}

enum CRMViewCopy {
    static let actionWarningTitle = "Relationship update was not saved"
    static let dismissActionWarningAccessibilityLabel = "Dismiss relationship update warning"
    static let localSaveFailedMessage = "Could not save the relationship update on this device. Your people list stayed unchanged."
    static let remoteSaveFailedMessage = "Maraithon updated the relationship. Refresh people to show the latest state on this device."
    static let restoreFailedMessage = "Could not restore this relationship after the update failed. Refresh people to show the latest state."
    static let reachedOutActionTitle = "Reached out"
    static let addPersonAccessibilityLabel = "Add person"

    static var localSaveFailureLabels: [String] {
        [
            actionWarningTitle,
            dismissActionWarningAccessibilityLabel,
            localSaveFailedMessage,
            remoteSaveFailedMessage,
            restoreFailedMessage
        ]
    }
}
