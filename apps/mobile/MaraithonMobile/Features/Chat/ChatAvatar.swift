import SwiftUI

struct ChatAvatar: View {
    let title: String
    var systemImage: String?
    var size: CGFloat = 44
    var tint: Color = .accentColor

    var body: some View {
        Circle()
            .fill(tint.opacity(0.16))
            .frame(width: size, height: size)
            .overlay {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: size * 0.42, weight: .semibold))
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
