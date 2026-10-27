/// A consistent, accessible answer to who has the ball, separate from work state.
import SwiftUI

public struct TodoOwnershipLabel: View {
    public let workflow: TodoWorkflow
    public var showsState: Bool

    public init(workflow: TodoWorkflow, showsState: Bool = true) {
        self.workflow = workflow
        self.showsState = showsState
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { owner; state }
            VStack(alignment: .leading, spacing: 4) { owner; state }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(workflow.ballLabel). State: \(workflow.label)")
    }

    private var owner: some View {
        Label(workflow.ballLabel, systemImage: "person.crop.circle.fill")
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var state: some View {
        if showsState {
            Text(workflow.label).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
