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
            HStack(spacing: 8) {
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
            HStack(spacing: 7) {
                Text(option.title)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Text(option.count.formatted())
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(countBackground, in: Capsule())
            }
            .foregroundStyle(foregroundStyle)
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .background(chipBackground, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(borderColor, lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.title), \(option.count.formatted()) \(accessibilityNoun)")
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var foregroundStyle: Color {
        isSelected ? .white : .primary
    }

    private var chipBackground: Color {
        isSelected ? option.tint : Color(uiColor: .secondarySystemFill)
    }

    private var countBackground: Color {
        isSelected ? .white.opacity(0.2) : Color(uiColor: .tertiarySystemFill)
    }

    private var borderColor: Color {
        isSelected ? option.tint.opacity(0.45) : Color(uiColor: .separator).opacity(0.25)
    }
}
