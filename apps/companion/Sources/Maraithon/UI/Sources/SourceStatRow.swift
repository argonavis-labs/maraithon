import SwiftUI

/// Card row for one source detail metric: muted title and caption on the
/// left, tabular value on the right.
struct SourceStatRow: View {
    let stat: SourceStat

    var body: some View {
        RunnerKeyValueRow(label: stat.title, caption: stat.caption, value: stat.value)
    }
}
