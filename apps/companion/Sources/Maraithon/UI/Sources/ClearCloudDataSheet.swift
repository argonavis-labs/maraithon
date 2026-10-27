import SwiftUI

/// Destructive confirmation sheet shared across data-management panes.
///
/// Accepts a per-source body string so each pane can frame the
/// consequence in its own language.
struct ClearCloudDataSheet: View {
    @Binding var isPresented: Bool
    let description: String
    /// Destructive action: deletes Maraithon's stored copy for this source.
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
                Label(ClearCloudDataSheetCopy.irreversibleTitle, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(StatusTone.attention.color)
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section(ClearCloudDataSheetCopy.confirmSectionTitle) {
                TextField(ClearCloudDataSheetCopy.confirmPrompt, text: $typed)
                    .textFieldStyle(.roundedBorder)
            }
            if let onResetLocalCursor {
                Section(ClearCloudDataSheetCopy.resetSectionTitle) {
                    Text(ClearCloudDataSheetCopy.resetDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        onResetLocalCursor()
                        isPresented = false
                    } label: {
                        Label(ClearCloudDataSheetCopy.resetButtonTitle, systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 360, minHeight: 320)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(ClearCloudDataSheetCopy.cancelTitle) { isPresented = false }
            }
            ToolbarItem(placement: .destructiveAction) {
                Button(ClearCloudDataSheetCopy.deleteButtonTitle) {
                    onConfirmClearCloud()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!canConfirm)
            }
        }
        .navigationTitle(ClearCloudDataSheetCopy.navigationTitle)
    }
}

enum ClearCloudDataSheetCopy {
    static let irreversibleTitle = "This cannot be undone"
    static let confirmSectionTitle = "Confirm"
    static let confirmPrompt = "Type \"delete\" to confirm"
    static let resetSectionTitle = "Check Source From Beginning"
    static let resetDescription = "Check this source from the beginning on this Mac. Maraithon's copy is left untouched."
    static let resetButtonTitle = "Check from the beginning"
    static let cancelTitle = "Cancel"
    static let deleteButtonTitle = "Delete Maraithon's copy"
    static let navigationTitle = "Delete Maraithon's copy"
}
