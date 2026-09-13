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
            RunnerTabs(
                items: [
                    RunnerTabs<Bool>.Item(id: false, title: "People"),
                    RunnerTabs<Bool>.Item(id: true, title: "Details")
                ],
                selection: $showsDetails
            )
            .padding(.top, Runner.Spacing.small)
            .accessibilityLabel("Todo context")

            ScrollView {
                VStack(alignment: .leading, spacing: Runner.Spacing.medium) {
                    if showsDetails {
                        details
                    } else if let people, !people.isEmpty {
                        ForEach(people) { person in
                            RunnerCard {
                                VStack(alignment: .leading, spacing: Runner.Spacing.compact) {
                                    Label(person.name, systemImage: "person.crop.circle")
                                        .font(Runner.Typography.bodyMedium)
                                        .foregroundStyle(Runner.Palette.foreground)
                                    if let relationship = person.relationship, !relationship.isEmpty {
                                        Text(relationship)
                                            .font(Runner.Typography.small)
                                            .foregroundStyle(Runner.Palette.mutedForeground)
                                    }
                                    if let context = person.context {
                                        Text(context)
                                            .font(Runner.Typography.small)
                                            .foregroundStyle(Runner.Palette.foreground80)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .textSelection(.enabled)
                                    }
                                    Button("Ask about \(person.name)", systemImage: "bubble.left") {
                                        ask(person.question)
                                    }
                                    .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
                                    .disabled(actionsDisabled)
                                    .padding(.top, Runner.Spacing.xsmall)
                                }
                                .runnerCardRow()
                            }
                        }
                    } else if !hasBrief {
                        Text("People will appear here when this todo’s context is ready.")
                            .font(Runner.Typography.small)
                            .foregroundStyle(Runner.Palette.mutedForeground)
                    } else {
                        Text("No people identified for this todo.")
                            .font(Runner.Typography.small)
                            .foregroundStyle(Runner.Palette.mutedForeground)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Runner.Layout.pageInset)
            }
        }
        .background(Runner.Palette.background)
    }
}
