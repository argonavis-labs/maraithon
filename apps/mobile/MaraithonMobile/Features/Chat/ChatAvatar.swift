import SwiftUI

/// Initials or symbol mark on the workspace's selected tint. The transcript
/// no longer shows avatars; this stays for surfaces that still want a mark.
struct ChatAvatar: View {
    let title: String
    var systemImage: String?
    var size: CGFloat = Runner.Layout.controlHeight
    var tint: Color = Runner.Palette.accent

    var body: some View {
        Circle()
            .fill(Runner.Palette.selected)
            .frame(width: size, height: size)
            .overlay {
                Circle()
                    .stroke(Runner.Palette.border, lineWidth: Runner.Stroke.hairline)
            }
            .overlay {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: size * 0.42, weight: .medium))
                        .foregroundStyle(tint)
                } else {
                    Text(initials)
                        .font(.system(size: size * 0.32, weight: .semibold))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .accessibilityHidden(true)
    }

    private var initials: String {
        let value = title
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()

        return value.isEmpty ? "M" : value
    }
}
