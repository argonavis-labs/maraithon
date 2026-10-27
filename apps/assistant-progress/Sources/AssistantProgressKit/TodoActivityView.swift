/// A compact chronological record; expanding an event reveals its preserved context.
import SwiftUI

public struct TodoActivityView: View {
    let entries: [TodoActivity]
    @State private var expanded = false

    public init(entries: [TodoActivity]) { self.entries = entries }

    public var body: some View {
        if !entries.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        DisclosureGroup {
                            if let body = entry.body, !body.isEmpty {
                                Text(body).font(.callout).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 8)
                            }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Label(entry.title, systemImage: entry.symbol)
                                    .foregroundStyle(entry.kind == "sent" || entry.kind == "marked_done" ? Color.green : Color.primary)
                                Spacer(minLength: 8)
                                if let date = entry.date {
                                    Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.font(.callout)
                        }
                    }
                }.padding(.top, 8)
            } label: {
                Label("Timeline · \(entries.count)", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
            }
        }
    }
}
