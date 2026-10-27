/// The same three review actions in Triage rows and details. Completion is
/// separate from acceptance, and actions stack when text needs more room.
import SwiftUI

struct TriageTodoActions: View {
    var addTitle = "Add"
    let complete: () -> Void
    let accept: () -> Void
    let ignore: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Runner.Spacing.small) { buttons }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: Runner.Spacing.small) { buttons }
        }
    }

    @ViewBuilder private var buttons: some View {
        Button(action: ignore) { Label("Ignore", systemImage: "hand.thumbsdown") }
            .buttonStyle(RunnerButtonStyle(.plain, compact: true))
        Button(action: complete) { Label("Done", systemImage: "checkmark.circle") }
            .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
            .accessibilityLabel("Mark done")
        Button(action: accept) { Label(addTitle, systemImage: "plus") }
            .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
            .accessibilityLabel("Add to Todos")
    }
}
