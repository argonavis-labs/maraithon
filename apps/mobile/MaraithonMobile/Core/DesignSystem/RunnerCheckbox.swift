import SwiftUI

/// 22pt rounded checkbox with the accent fill, sized for touch.
struct RunnerCheckbox: View {
    let isOn: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: Runner.Radius.checkbox, style: .continuous)
                    .fill(isOn ? Runner.Palette.accent : Runner.Palette.background)
                RoundedRectangle(cornerRadius: Runner.Radius.checkbox, style: .continuous)
                    .stroke(isOn ? Runner.Palette.accent : Runner.Palette.ring, lineWidth: Runner.Stroke.control)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(Runner.Typography.checkmark)
                        .foregroundStyle(.white)
                }
            }
            .frame(width: Runner.Layout.checkboxSize, height: Runner.Layout.checkboxSize)
            .frame(minWidth: Runner.Layout.controlHeight, minHeight: Runner.Layout.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "Done" : "Open")
    }
}
