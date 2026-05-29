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
                            title: "Relationship update was not saved",
                            message: actionErrorMessage,
                            buttonTitle: nil,
                            retry: nil,
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
        try? modelContext.save()

        guard let sessionToken = sessionStore.user?.sessionToken else { return }

        Task {
            do {
                let remote = try await MobileAPIClient().updatePerson(
                    sessionToken: sessionToken,
                    id: contact.id,
                    payload: ProductionDataSync.personPayload(from: contact)
                )
                ProductionDataSync.apply(remote, to: contact)
                try? modelContext.save()
            } catch {
                snapshot.restore(to: contact)
                try? modelContext.save()
                actionErrorMessage = "\(action.failurePrefix) \(MobileErrorCopy.message(for: error))"
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
}

enum CRMViewCopy {
    static let reachedOutActionTitle = "Reached out"
    static let addPersonAccessibilityLabel = "Add person"
}
