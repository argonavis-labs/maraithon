import SwiftData
import SwiftUI

struct CRMView: View {
    @Environment(AppNavigation.self) private var appNavigation
    @Environment(\.modelContext) private var modelContext
    @Environment(SessionStore.self) private var sessionStore
    @Query(sort: \CRMContact.name) private var contacts: [CRMContact]
    @Query(sort: \TodoItem.createdAt, order: .reverse) private var todos: [TodoItem]
    @State private var isAddingContact = false
    @State private var editingContact: CRMContact?
    @State private var searchText = ""
    @State private var selectedTab: PeopleFocusTab = .suggested
    @State private var refreshErrorMessage: String?
    @State private var actionErrorMessage: String?
    @State private var isRefreshing = false
    @State private var goals: [MobileAPIClient.RemoteGoal] = []
    @State private var reconnectSuggestions: [MobileAPIClient.RemoteReconnectSuggestion] = []

    private var peopleContexts: [PeopleContactContext] {
        PeoplePriorityEngine.contexts(
            contacts: contacts,
            todos: todos,
            goals: goals,
            suggestions: reconnectSuggestions,
            searchText: searchText
        )
    }

    private var selectedPeopleContexts: [PeopleContactContext] {
        PeoplePriorityEngine.contexts(
            for: selectedTab,
            contexts: peopleContexts,
            suggestions: reconnectSuggestions
        )
    }

    private var focusCounts: PeopleFocusCounts {
        PeoplePriorityEngine.counts(from: peopleContexts)
    }

    private var emptyState: PeopleEmptyState {
        selectedTab.emptyState(searchText: searchText, hasAnyPeople: !contacts.isEmpty)
    }

    var body: some View {
        NavigationStack {
            List {
                if let refreshErrorMessage {
                    Section {
                        SyncIssueBanner(
                            message: refreshErrorMessage,
                            retry: { Task { await refreshPriorityPeople() } },
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
                                count: focusCounts.value(for: tab),
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
                    if selectedPeopleContexts.isEmpty {
                        ContentUnavailableView(
                            emptyState.title,
                            systemImage: emptyState.systemImage,
                            description: Text(emptyState.description)
                        )
                    } else {
                        ForEach(selectedPeopleContexts) { context in
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
                await refreshPriorityPeople()
            }
            .refreshable {
                await refreshPriorityPeople()
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

    private func refreshPriorityPeople() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            try await ProductionDataSync.refreshPeople(
                sessionStore: sessionStore,
                modelContext: modelContext
            )
            try await ProductionDataSync.refreshTodos(
                sessionStore: sessionStore,
                modelContext: modelContext,
                includeCards: false
            )
            refreshErrorMessage = nil
        } catch {
            refreshErrorMessage = "Could not refresh people and work. \(MobileErrorCopy.message(for: error))"
        }

        await refreshGoals()
        await refreshReconnectSuggestions()
    }

    private func refreshGoals() async {
        guard let sessionToken = sessionStore.user?.sessionToken else {
            goals = []
            return
        }

        do {
            let remoteGoals = try await MobileAPIClient().listGoals(
                sessionToken: sessionToken,
                status: "active",
                category: "all",
                limit: 100
            )
            await MainActor.run { goals = remoteGoals }
        } catch {
            await MainActor.run { goals = [] }
        }
    }

    private func refreshReconnectSuggestions() async {
        guard let sessionToken = sessionStore.user?.sessionToken else { return }

        do {
            let suggestions = try await MobileAPIClient().reconnectSuggestions(sessionToken: sessionToken)
            await MainActor.run { reconnectSuggestions = suggestions }
        } catch {
            // The reconnect surface is additive intelligence on top of the
            // directory; if it cannot load we silently fall back to the list
            // rather than blocking people management with an error banner.
            await MainActor.run { reconnectSuggestions = [] }
        }
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
