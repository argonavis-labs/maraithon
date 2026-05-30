import SwiftUI

struct SyncIssueBanner: View {
    let title: String
    let message: String
    let buttonTitle: String?
    let retry: (() -> Void)?
    let dismissAccessibilityLabel: String
    let dismiss: () -> Void

    init(
        title: String = "Latest data may be out of date",
        message: String,
        buttonTitle: String? = "Retry",
        retry: (() -> Void)? = nil,
        dismissAccessibilityLabel: String = "Dismiss warning",
        dismiss: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.buttonTitle = buttonTitle
        self.retry = retry
        self.dismissAccessibilityLabel = dismissAccessibilityLabel
        self.dismiss = dismiss
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let buttonTitle, let retry {
                Button(buttonTitle, action: retry)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(dismissAccessibilityLabel)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
