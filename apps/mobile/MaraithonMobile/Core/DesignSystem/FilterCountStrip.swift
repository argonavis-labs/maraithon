import SwiftUI

struct FilterCountOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    let count: Int
    let tint: Color

    var id: Value { value }
}

struct FilterCountStrip<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [FilterCountOption<Value>]
    var accessibilityNoun = "items"

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Runner.Spacing.small) {
                ForEach(options) { option in
                    FilterCountButton(
                        option: option,
                        isSelected: selection == option.value,
                        accessibilityNoun: accessibilityNoun
                    ) {
                        withAnimation(.snappy(duration: 0.2)) {
                            selection = option.value
                        }
                    }
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .scrollIndicators(.hidden)
    }
}

private struct FilterCountButton<Value: Hashable>: View {
    let option: FilterCountOption<Value>
    let isSelected: Bool
    let accessibilityNoun: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Runner.Spacing.compact) {
                Text(option.title)
                    .font(isSelected ? Runner.Typography.smallMedium : Runner.Typography.small)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Text(option.count.formatted())
                    .font(Runner.Typography.micro.monospacedDigit())
                    .lineLimit(1)
                    .padding(.horizontal, Runner.Spacing.xsmall + 1)
                    .padding(.vertical, 1)
                    .background(countBackground, in: Capsule())
            }
            .foregroundStyle(isSelected ? Runner.Palette.background : Runner.Palette.foreground)
            .padding(.horizontal, Runner.Spacing.tight)
            .frame(minHeight: Runner.Layout.compactControlHeight)
            .background(isSelected ? Runner.Palette.foreground : Runner.Palette.background, in: Capsule())
            .overlay {
                Capsule().stroke(isSelected ? Runner.Palette.foreground : Runner.Palette.border, lineWidth: Runner.Stroke.hairline)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.title), \(option.count.formatted()) \(accessibilityNoun)")
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var countBackground: Color {
        isSelected ? Runner.Palette.background.opacity(0.2) : Runner.Palette.foreground5
    }
}
