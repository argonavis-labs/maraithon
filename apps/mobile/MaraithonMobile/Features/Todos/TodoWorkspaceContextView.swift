import SwiftUI

struct TodoWorkspaceContextView: View {
    let people: [TodoWorkspacePerson]?
    let hasBrief: Bool
    let actionsDisabled: Bool
    let ask: (String) -> Void
    let details: AnyView
    @State private var showsDetails = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Todo context", selection: $showsDetails) {
                Text("People").tag(false)
                Text("Details").tag(true)
            }.pickerStyle(.segmented).padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if showsDetails {
                        details
                    } else if let people, !people.isEmpty {
                        ForEach(people) { person in
                            VStack(alignment: .leading, spacing: 10) {
                                Label(person.name, systemImage: "person.crop.circle")
                                    .font(.headline)
                                if let relationship = person.relationship, !relationship.isEmpty {
                                    Text(relationship).font(.subheadline).foregroundStyle(.secondary)
                                }
                                if let context = person.context {
                                    Text(context).font(.subheadline).textSelection(.enabled)
                                }
                                Button("Ask about \(person.name)", systemImage: "bubble.left") {
                                    ask(person.question)
                                }.buttonStyle(.bordered).disabled(actionsDisabled)
                            }
                            Divider()
                        }
                    } else if !hasBrief {
                        Text("People will appear here when this todo’s context is ready.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text("No people identified for this todo.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}
