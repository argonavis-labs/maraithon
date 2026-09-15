/// Search and refresh row under the view tabs. Searches stay explicit
/// (submit to run) so the store's paging stays predictable.
import SwiftUI
import AssistantProgressKit

struct TodosFilterView: View {
    @Bindable var store: TodosStore
    @FocusState.Binding var searchFocused: Bool

    var body: some View {
        HStack(spacing: Tokens.Spacing.medium) {
            RunnerSearchField(
                placeholder: "Search tasks…",
                text: $store.query,
                focused: $searchFocused,
                onSubmit: { Task { await store.load() } },
                onClear: {
                    store.query = ""
                    Task { await store.load() }
                }
            )
            .frame(maxWidth: Tokens.Layout.searchFieldMaxWidth)
            .accessibilityLabel("Search tasks")

            Picker("Personal or work", selection: $store.category) {
                ForEach(TaskCategory.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .onChange(of: store.category) { _, _ in Task { await store.load() } }

            Spacer(minLength: Tokens.Spacing.medium)

            Button {
                Task { await store.load() }
            } label: {
                HStack(spacing: Tokens.Spacing.compact) {
                    Image(systemName: "arrow.clockwise")
                        .accessibilityHidden(true)
                    Text("Refresh")
                }
            }
            .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
            .disabled(store.isLoading)
        }
        .padding(.vertical, Tokens.Spacing.medium)
    }
}
