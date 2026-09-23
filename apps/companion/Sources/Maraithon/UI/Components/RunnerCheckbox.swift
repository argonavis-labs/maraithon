import SwiftUI

/// 14pt square checkbox with the accent fill the web task table uses.
/// Always labeled for VoiceOver; the visual is intentionally quiet.
struct RunnerCheckbox: View {
    let isOn: Bool
    let label: String
    let action: () -> Void
    var tint: Color = Tokens.Palette.accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: Tokens.CornerRadius.checkbox)
                    .fill(isOn ? tint : Tokens.Palette.background)
                RoundedRectangle(cornerRadius: Tokens.CornerRadius.checkbox)
                    .stroke(isOn ? tint : Tokens.Palette.ring, lineWidth: Tokens.Stroke.control)
                Image(systemName: "checkmark")
                    .font(Tokens.Typography.checkmark)
                    .foregroundStyle(.white)
                    .opacity(isOn ? 1 : 0)
                    .scaleEffect(isOn || reduceMotion ? 1 : 0.5)
            }
            .frame(width: Tokens.Layout.checkboxSize, height: Tokens.Layout.checkboxSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .default, value: isOn)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "Selected" : "Not selected")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
