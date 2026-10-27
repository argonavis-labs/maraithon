import SwiftUI

/// Hairline search field with a leading magnifier and a clear button.
struct RunnerSearchField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: Runner.Spacing.small) {
            Image(systemName: "magnifyingglass")
                .font(Runner.Typography.small)
                .foregroundStyle(Runner.Palette.mutedForeground)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .font(Runner.Typography.body)
                .foregroundStyle(Runner.Palette.foreground)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Runner.Typography.small)
                        .foregroundStyle(Runner.Palette.mutedForeground)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Runner.Spacing.tight)
        .frame(height: Runner.Layout.controlHeight)
        .background(Runner.Palette.background, in: RoundedRectangle(cornerRadius: Runner.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Runner.Radius.control, style: .continuous)
                .stroke(Runner.Palette.border, lineWidth: Runner.Stroke.hairline)
        }
    }
}
