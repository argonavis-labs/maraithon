import SwiftUI

/// Destructive confirmation sheet shared across data-management panes.
///
/// Accepts a per-source body string so each pane can frame the
/// consequence in its own language.
struct ClearCloudDataSheet: View {
    @Binding var isPresented: Bool
    let description: String
    /// Destructive action: deletes synced data for this source.
    var onConfirmClearCloud: () -> Void
    /// Non-destructive action: drops the local cursor and lets the next
    /// polling tick repopulate.
    var onResetLocalCursor: (() -> Void)? = nil

    @State private var typed: String = ""

    private var canConfirm: Bool {
        typed.lowercased() == "delete"
    }

    var body: some View {
        Form {
            Section {
                Label("This cannot be undone", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(StatusTone.attention.color)
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Confirm") {
                TextField("Type \"delete\" to confirm", text: $typed)
                    .textFieldStyle(.roundedBorder)
            }
            if let onResetLocalCursor {
                Section("Re-sync Source") {
                    Text("Re-sync this source from this Mac. Maraithon's synced copy is left untouched.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        onResetLocalCursor()
                        isPresented = false
                    } label: {
                        Label("Re-sync this source", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 360, minHeight: 320)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { isPresented = false }
            }
            ToolbarItem(placement: .destructiveAction) {
                Button("Delete synced data") {
                    onConfirmClearCloud()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!canConfirm)
            }
        }
        .navigationTitle("Delete synced data")
    }
}
