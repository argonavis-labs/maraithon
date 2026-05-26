import SwiftUI

struct StatusPill: View {
    let title: String
    var tint: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
    }
}
