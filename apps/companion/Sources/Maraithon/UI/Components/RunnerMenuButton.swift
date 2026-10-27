import SwiftUI

/// Hairline dropdown that looks like the secondary button ("Sort  Affinity ⌄")
/// and opens a themed option list in a popover. Options are plain buttons so
/// keyboard and VoiceOver behave normally.
struct RunnerMenuButton: View {
    struct Option: Identifiable {
        let id: String
        let title: String
        let action: () -> Void
    }

    let label: String
    let value: String
    let options: [Option]

    @State private var hovering = false
    @State private var open = false

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: Tokens.Spacing.compact) {
                Text(label)
                    .foregroundStyle(Tokens.Palette.mutedForeground)
                Text(value)
                    .foregroundStyle(Tokens.Palette.foreground)
                Image(systemName: "chevron.down")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.mutedForeground)
                    .accessibilityHidden(true)
            }
            .font(Tokens.Typography.small)
            .padding(.horizontal, Tokens.Spacing.snug)
            .frame(height: Tokens.Layout.controlHeight)
            .background(
                hovering || open ? Tokens.Palette.foreground3 : .clear,
                in: RoundedRectangle(cornerRadius: Tokens.CornerRadius.control)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.CornerRadius.control)
                    .stroke(Tokens.Palette.border, lineWidth: Tokens.Stroke.hairline)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(label): \(value)")
        .accessibilityHint("Opens a list of choices")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(options) { option in
                    RunnerMenuRow(title: option.title, isSelected: option.title == value) {
                        open = false
                        option.action()
                    }
                }
            }
            .padding(Tokens.Spacing.xsmall)
            .frame(width: Tokens.PeopleLayout.sortMenuWidth)
            .background(Tokens.Palette.surfaceRaised)
        }
    }
}

private struct RunnerMenuRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Spacing.small) {
                Text(title)
                    .font(isSelected ? Tokens.Typography.bodyMedium : Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.foreground)
                Spacer(minLength: Tokens.Spacing.small)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Tokens.Spacing.snug)
            .padding(.vertical, Tokens.Spacing.compact + 1)
            .background(hovering ? Tokens.Palette.foreground5 : .clear, in: RoundedRectangle(cornerRadius: Tokens.CornerRadius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
