import SwiftUI

/// Column header band for the task table. Column widths are shared with
/// `TodoRow` through `Tokens.Layout` so cells line up.
struct TodoTableHeader: View {
    let allSelected: Bool
    let hasRows: Bool
    let toggleAll: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            RunnerCheckbox(isOn: allSelected && hasRows, label: "Select all tasks", action: toggleAll)
                .padding(.leading, Tokens.Spacing.tight)
                .frame(width: Tokens.Layout.taskCheckboxColumn, alignment: .leading)
                .disabled(!hasRows)
            Text("Task")
                .padding(.horizontal, Tokens.Spacing.tight)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Source")
                .padding(.horizontal, Tokens.Spacing.tight)
                .frame(width: Tokens.Layout.taskSourceColumn, alignment: .leading)
            Text("Due")
                .padding(.horizontal, Tokens.Spacing.tight)
                .frame(width: Tokens.Layout.taskDueColumn, alignment: .leading)
            Text("Action")
                .padding(.horizontal, Tokens.Spacing.tight)
                .frame(width: Tokens.Layout.taskActionColumn, alignment: .trailing)
        }
        .font(Tokens.Typography.caption)
        .foregroundStyle(Tokens.Palette.mutedForeground)
        .padding(.vertical, Tokens.Spacing.snug)
        .background(Tokens.Palette.foreground3, in: RoundedRectangle(cornerRadius: Tokens.CornerRadius.control - 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Task table header")
    }
}
