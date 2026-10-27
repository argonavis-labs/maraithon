import SwiftUI

/// Action styles used across features. These names predate the workspace
/// theme; they now resolve to the Runner button styles so call sites stay put.
extension View {
    func appGlassActionStyle() -> some View {
        buttonStyle(RunnerButtonStyle(.secondary, compact: true))
    }

    func appProminentGlassActionStyle() -> some View {
        buttonStyle(RunnerButtonStyle(.primary, compact: true))
    }

    func appProminentGlassCircleActionStyle() -> some View {
        buttonStyle(RunnerCircleButtonStyle())
    }

    func appInteractiveGlassCapsule() -> some View {
        self
            .background(Runner.Palette.background, in: Capsule())
            .overlay { Capsule().stroke(Runner.Palette.border, lineWidth: Runner.Stroke.hairline) }
    }

    func appInteractiveGlassCircle() -> some View {
        self
            .background(Runner.Palette.background, in: Circle())
            .overlay { Circle().stroke(Runner.Palette.border, lineWidth: Runner.Stroke.hairline) }
    }
}

/// Ink circle used for the single prominent icon action (send, compose).
struct RunnerCircleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Runner.Typography.icon)
            .foregroundStyle(Runner.Palette.background)
            .frame(width: Runner.Layout.controlHeight, height: Runner.Layout.controlHeight)
            .background(Runner.Palette.foreground, in: Circle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(Circle())
    }
}
