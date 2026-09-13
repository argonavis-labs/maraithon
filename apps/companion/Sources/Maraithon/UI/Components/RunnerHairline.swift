import SwiftUI

/// Half-point horizontal rule in the workspace border color. The only
/// separator the custom theme uses; never reach for `Divider()`.
struct RunnerHairline: View {
    var body: some View {
        Rectangle()
            .fill(Tokens.Palette.border)
            .frame(height: Tokens.Stroke.hairline)
            .accessibilityHidden(true)
    }
}
