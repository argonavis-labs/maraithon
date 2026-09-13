import SwiftUI

/// Small status badge. Keeps its `tint` API; renders with the workspace
/// badge recipe (tinted fill, ink-mixed text) instead of a capsule.
struct StatusPill: View {
    let title: String
    var tint: Color

    var body: some View {
        RunnerBadge(text: title, tone: RunnerBadge.Tone.from(tint: tint))
    }
}
