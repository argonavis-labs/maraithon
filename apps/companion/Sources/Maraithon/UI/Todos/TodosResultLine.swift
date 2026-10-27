/// Current task count and filter, kept stable during background refreshes.
import SwiftUI

struct TodosResultLine: View {
    let store: TodosStore

    var body: some View {
        HStack {
            Text(TodosCopy.showingLine(count: store.todos.count, isLoading: store.isLoading))
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.mutedForeground)
                .contentTransition(.numericText())
            Spacer()
            Text(store.filter.title)
                .font(Tokens.Typography.micro)
                .foregroundStyle(Tokens.Palette.mutedForeground)
        }
        .padding(.bottom, Tokens.Spacing.snug)
    }
}
