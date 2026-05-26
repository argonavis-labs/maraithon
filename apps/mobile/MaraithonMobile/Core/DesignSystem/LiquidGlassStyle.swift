import SwiftUI

extension View {
    func appGlassActionStyle() -> some View {
        buttonStyle(.glass)
    }

    func appProminentGlassActionStyle() -> some View {
        buttonStyle(.glassProminent)
    }

    func appProminentGlassCircleActionStyle() -> some View {
        buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
    }

    func appInteractiveGlassCapsule() -> some View {
        glassEffect(.regular.interactive(), in: Capsule())
    }

    func appInteractiveGlassCircle() -> some View {
        glassEffect(.regular.interactive(), in: Circle())
    }
}
