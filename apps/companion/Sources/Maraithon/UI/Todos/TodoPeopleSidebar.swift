/// People stay beside the work, with source-grounded context and a direct way to ask about each person.
import SwiftUI

struct TodoPeopleSidebar: View {
    let store: TodoConversationStore
    @Binding var showsDetails: Bool
    let details: AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Todo context", selection: $showsDetails) {
                Text("People").tag(false)
                Text("Details").tag(true)
            }.pickerStyle(.segmented).padding(Tokens.Spacing.medium)
            Divider()
            if showsDetails {
                details
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.large) {
                        if let people = store.todo.brief?.people, !people.isEmpty {
                            ForEach(people) { person in
                                VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
                                    Label(person.name, systemImage: "person.crop.circle").font(.headline)
                                    if let relationship = person.relationship, !relationship.isEmpty {
                                        Text(relationship).font(.callout).foregroundStyle(.secondary)
                                    }
                                    if let context = person.context {
                                        Text(context).font(.callout).textSelection(.enabled)
                                    }
                                    Button("Ask about \(person.name)", systemImage: "bubble.left") {
                                        Task { await store.send("Who is \(person.name), how do I know them, and what should I know for this todo? Check our real relationship and source history.") }
                                    }.controlSize(.small).disabled(store.thread == nil || store.isSending)
                                }
                                Divider()
                            }
                        } else if store.todo.brief == nil {
                            ProgressView("Finding the people involved…").controlSize(.small)
                        } else {
                            Text("No people identified for this todo.").font(.callout).foregroundStyle(.secondary)
                        }
                        if let source = store.todo.actionCard?.sourceAction, let url = source.destination {
                            Text("Source").font(.headline)
                            Link(destination: url) { Label(source.openLabel ?? "Open original", systemImage: "arrow.up.right") }
                        }
                    }.padding(Tokens.Spacing.medium).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minWidth: Tokens.Layout.todoPeopleMinWidth, idealWidth: Tokens.Layout.todoPeopleWidth,
               maxWidth: Tokens.Layout.todoPeopleMaxWidth, maxHeight: .infinity, alignment: .topLeading)
    }
}
