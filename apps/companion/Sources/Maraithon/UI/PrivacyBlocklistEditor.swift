import SwiftUI

enum PrivacyBlocklistEditorCopy {
    static let sectionTitle = "Never include"
    static let description = "Add phone numbers or emails you never want included. Matching Messages stay on this Mac."
    static let emptyMessage = "No phone numbers or emails are excluded. Add one to keep matching Messages out of assistant context."
    static let inputPlaceholder = "Phone number or email"
    static let addButtonTitle = "Add"
    static let removeButtonTitle = "Remove"

    static func removeAccessibilityLabel(for handle: String) -> String {
        "Remove \(handle) from never include list"
    }
}

/// Inline editor for the local-only `Blocklist`. Phone numbers and
/// emails added here are filtered before sources push, so the server
/// never sees them.
///
/// Invariants:
/// - Reads and writes go through the `Blocklist` actor; this view holds
///   no parallel copy of the handle set.
/// - The form sits inside `SettingsView`'s Privacy tab and uses
///   `Form`/`Section` primitives — no custom row chrome.
struct PrivacyBlocklistEditor: View {
    @Environment(AppEnvironment.self) private var env
    @State private var draft: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        Section(PrivacyBlocklistEditorCopy.sectionTitle) {
            Text(PrivacyBlocklistEditorCopy.description)
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: Tokens.Spacing.small) {
                TextField(PrivacyBlocklistEditorCopy.inputPlaceholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(commit)
                Button {
                    commit()
                } label: {
                    Label(PrivacyBlocklistEditorCopy.addButtonTitle, systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .disabled(trimmedDraft.isEmpty)
                .keyboardShortcut(.defaultAction)
            }

            if sortedHandles.isEmpty {
                Text(PrivacyBlocklistEditorCopy.emptyMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sortedHandles, id: \.self) { handle in
                    HStack {
                        Image(systemName: handle.contains("@") ? "envelope" : "phone")
                            .foregroundStyle(.secondary)
                            .frame(width: Tokens.IconSize.inline)
                        Text(handle)
                            .font(.body.monospaced())
                        Spacer()
                        Button(role: .destructive) {
                            env.blocklist.remove(handle)
                            env.eventLog.info(
                                "blocklist.remove",
                                source: .ui,
                                payload: ["handle_hash": String(handle.hashValue)]
                            )
                        } label: {
                            Label(PrivacyBlocklistEditorCopy.removeButtonTitle, systemImage: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(PrivacyBlocklistEditorCopy.removeAccessibilityLabel(for: handle))
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private var sortedHandles: [String] {
        env.blocklist.handles.sorted()
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit() {
        let handle = trimmedDraft
        guard !handle.isEmpty else { return }
        env.blocklist.add(handle)
        env.eventLog.info(
            "blocklist.add",
            source: .ui,
            payload: ["handle_hash": String(handle.hashValue)]
        )
        draft = ""
        fieldFocused = true
    }
}
