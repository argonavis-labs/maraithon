/// Inline manual capture retains its request identity through a failed retry.
import SwiftUI

public struct TodoQuickEntry: View {
    let create: (String, UUID) async throws -> Void
    let focusChanged: (Bool) -> Void
    let autofocus: Bool
    @FocusState private var focused: Bool
    @State private var title = ""
    @State private var requestID = UUID()
    @State private var working = false
    @State private var error: String?

    public init(autofocus: Bool = false, focusChanged: @escaping (Bool) -> Void = { _ in },
                create: @escaping (String, UUID) async throws -> Void) {
        self.create = create
        self.focusChanged = focusChanged
        self.autofocus = autofocus
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Add a todo…", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .accessibilityLabel("New todo title")
                    .onSubmit(submit)
                    .disabled(working)
                    .onChange(of: title) { _, _ in requestID = UUID(); error = nil }
                if working { ProgressView().controlSize(.small) }
                Button(action: submit) { Label("Add todo", systemImage: "plus") }
                    .disabled(working || title.trimmingCharacters(in: .whitespacesAndNewlines).count < 4)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onChange(of: focused) { _, value in focusChanged(value) }
        .onDisappear { focusChanged(false) }
        .task { if autofocus { focused = true } }
    }

    private func submit() {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !working, value.count >= 4 else { return }
        working = true
        error = nil
        let id = requestID
        Task { @MainActor in
            defer { working = false }
            do {
                try await create(value, id)
                title = ""
                requestID = UUID()
            } catch {
                self.error = "Could not add this todo. Please try again."
            }
        }
    }
}
