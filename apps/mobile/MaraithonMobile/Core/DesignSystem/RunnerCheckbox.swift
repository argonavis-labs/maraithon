import SwiftUI

/// 22pt rounded checkbox with the accent fill, sized for touch.
struct RunnerCheckbox: View {
    let isOn: Bool
    let label: String
    let action: () -> Void
    var tint: Color = Runner.Palette.accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: Runner.Radius.checkbox, style: .continuous)
                    .fill(isOn ? tint : Runner.Palette.background)
                RoundedRectangle(cornerRadius: Runner.Radius.checkbox, style: .continuous)
                    .stroke(isOn ? tint : Runner.Palette.ring, lineWidth: Runner.Stroke.control)
                Image(systemName: "checkmark")
                    .font(Runner.Typography.checkmark)
                    .foregroundStyle(.white)
                    .opacity(isOn ? 1 : 0)
                    .scaleEffect(isOn || reduceMotion ? 1 : 0.5)
            }
            .frame(width: Runner.Layout.checkboxSize, height: Runner.Layout.checkboxSize)
            .frame(minWidth: Runner.Layout.controlHeight, minHeight: Runner.Layout.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .default, value: isOn)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "Done" : "Open")
    }
}
