import SwiftData
import SwiftUI

struct CRMView: View {
    @Environment(AppNavigation.self) private var appNavigation
    @Environment(\.modelContext) private var modelContext
    @Environment(SessionStore.self) private var sessionStore
    @Query(sort: \CRMContact.name) private var contacts: [CRMContact]
    @State private var isAddingContact = false
    @State private var editingContact: CRMContact?
    @State private var searchText = ""
    @State private var statusFilter: CRMStatusFilter = .all
    @State private var refreshErrorMessage: String?
    @State private var actionErrorMessage: String?
    @State private var isRefreshing = false

    private var filteredContacts: [CRMContact] {
        CRMFiltering.filter(contacts, statusFilter: statusFilter, searchText: searchText)
    }

    private var statusCounts: CRMStatusCounts {
        CRMFiltering.counts(contacts, searchText: searchText)
    }

    private var emptyState: PeopleEmptyState {
        statusFilter.emptyState(searchText: searchText, hasAnyPeople: !contacts.isEmpty)
    }

    var body: some View {
        NavigationStack {
            List {
                if let refreshErrorMessage {
                    Section {
                        SyncIssueBanner(
                            message: refreshErrorMessage,
                            retry: { Task { await refreshLatestPeople() } },
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
                        selection: $statusFilter,
                        options: CRMStatusFilter.allCases.map { filter in
                            FilterCountOption(
                                value: filter,
                                title: filter.title,
                                count: statusCounts.value(for: filter),
                                tint: tint(for: filter)
                            )
                        },
                        accessibilityNoun: "people"
                    )
                    .padding(.vertical, 8)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                }

                Section("People") {
                    if filteredContacts.isEmpty {
                        ContentUnavailableView(
                            emptyState.title,
                            systemImage: emptyState.systemImage,
                            description: Text(emptyState.description)
                        )
                    } else {
                        ForEach(filteredContacts) { contact in
                            NavigationLink {
                                ContactDetailView(contact: contact)
                            } label: {
                                ContactRow(contact: contact)
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    apply(.markActive, to: contact)
                                } label: {
                                    Label("Active", systemImage: "person.crop.circle.fill.badge.checkmark")
                                }
                                .tint(.green)

                                Button {
                                    apply(.logContact(Date()), to: contact)
                                } label: {
                                    Label(CRMViewCopy.reachedOutActionTitle, systemImage: "phone.arrow.up.right")
                                }
                                .tint(.blue)
                            }
                            .swipeActions(edge: .trailing) {
                                Button {
                                    apply(.archive, to: contact)
                                } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                                .tint(.gray)

                                Button {
                                    editingContact = contact
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
                await refreshLatestPeople()
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

    private func refreshLatestPeople() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            try await ProductionDataSync.refreshPeople(
                sessionStore: sessionStore,
                modelContext: modelContext
            )
            refreshErrorMessage = nil
        } catch {
            refreshErrorMessage = "Could not refresh people. \(MobileErrorCopy.message(for: error))"
        }
    }

    private func tint(for filter: CRMStatusFilter) -> Color {
        switch filter {
        case .all: .accentColor
        case .lead: ContactStatus.lead.tint
        case .active: ContactStatus.active.tint
        case .atRisk: ContactStatus.atRisk.tint
        case .closed: ContactStatus.closed.tint
        }
    }

    private func applyRequestedFilterIfNeeded() {
        guard let requestedFilter = appNavigation.requestedPeopleFilter else { return }
        statusFilter = requestedFilter
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
