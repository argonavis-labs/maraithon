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

    private var filteredContacts: [CRMContact] {
        CRMFiltering.filter(contacts, statusFilter: statusFilter, searchText: searchText)
    }

    private var statusCounts: CRMStatusCounts {
        CRMFiltering.counts(contacts, searchText: searchText)
    }

    var body: some View {
        NavigationStack {
            List {
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
                            contacts.isEmpty ? "No People" : "No Matching People",
                            systemImage: "person.crop.circle.badge.plus",
                            description: Text(contacts.isEmpty ? "Add someone to start tracking the relationship." : "Adjust search or filters.")
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
                                    contact.status = .active
                                    save()
                                } label: {
                                    Label("Active", systemImage: "person.crop.circle.fill.badge.checkmark")
                                }
                                .tint(.green)

                                Button {
                                    contact.lastContactedAt = Date()
                                    save()
                                } label: {
                                    Label("Contacted", systemImage: "phone.arrow.up.right")
                                }
                                .tint(.blue)
                            }
                            .swipeActions(edge: .trailing) {
                                Button {
                                    contact.status = .closed
                                    contact.dealStage = .lost
                                    save()
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
                    .accessibilityLabel("Add Person")
                }
            }
            .sheet(isPresented: $isAddingContact) {
                ContactEditorView()
            }
            .sheet(item: $editingContact) { contact in
                ContactEditorView(contact: contact)
            }
            .task {
                try? await ProductionDataSync.refreshPeople(
                    sessionStore: sessionStore,
                    modelContext: modelContext
                )
            }
            .onAppear(perform: applyRequestedFilterIfNeeded)
            .onChange(of: appNavigation.requestedPeopleFilter) { _, _ in
                applyRequestedFilterIfNeeded()
            }
        }
    }

    private func save() {
        try? modelContext.save()
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
