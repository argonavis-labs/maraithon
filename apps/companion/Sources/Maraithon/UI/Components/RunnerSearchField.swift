import SwiftUI

/// Hairline search field with a leading magnifier and a trailing `/` hint
/// that swaps for a clear button once text is entered.
struct RunnerSearchField: View {
    let placeholder: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: Tokens.Spacing.small) {
            Image(systemName: "magnifyingglass")
                .font(Tokens.Typography.small)
                .foregroundStyle(Tokens.Palette.mutedForeground)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Tokens.Typography.small)
                .foregroundStyle(Tokens.Palette.foreground)
                .focused(focused)
                .onSubmit(onSubmit)
            if text.isEmpty {
                RunnerKeyCap(key: "/")
            } else {
                Button(action: onClear) {
                    Label("Clear search", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(Tokens.Typography.small)
                        .foregroundStyle(Tokens.Palette.mutedForeground)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Tokens.Spacing.snug)
        .frame(height: Tokens.Layout.controlHeight)
        .background(
            RoundedRectangle(cornerRadius: Tokens.CornerRadius.control)
                .stroke(focused.wrappedValue ? Tokens.Palette.ring : Tokens.Palette.border, lineWidth: Tokens.Stroke.hairline)
        )
        .contentShape(Rectangle())
        .onTapGesture { focused.wrappedValue = true }
    }
}
