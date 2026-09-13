import SwiftUI

/// 14pt square checkbox with the accent fill the web task table uses.
/// Always labeled for VoiceOver; the visual is intentionally quiet.
struct RunnerCheckbox: View {
    let isOn: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: Tokens.CornerRadius.checkbox)
                    .fill(isOn ? Tokens.Palette.accent : Tokens.Palette.background)
                RoundedRectangle(cornerRadius: Tokens.CornerRadius.checkbox)
                    .stroke(isOn ? Tokens.Palette.accent : Tokens.Palette.ring, lineWidth: Tokens.Stroke.control)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(Tokens.Typography.checkmark)
                        .foregroundStyle(.white)
                }
            }
            .frame(width: Tokens.Layout.checkboxSize, height: Tokens.Layout.checkboxSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "Selected" : "Not selected")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
