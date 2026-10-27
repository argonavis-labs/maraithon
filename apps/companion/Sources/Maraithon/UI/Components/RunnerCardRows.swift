import SwiftUI

/// A `RunnerCard` whose content is one row per element, separated by
/// hairlines. Rows supply their own inset via `.runnerCardRow()` so a row
/// can opt into a hover fill that reaches the card edge.
struct RunnerCardRows<Data: RandomAccessCollection, Row: View>: View where Data.Element: Identifiable {
    let data: Data
    @ViewBuilder let row: (Data.Element) -> Row

    var body: some View {
        RunnerCard {
            VStack(spacing: 0) {
                ForEach(Array(data.enumerated()), id: \.element.id) { index, element in
                    if index > 0 { RunnerHairline() }
                    row(element)
                }
            }
        }
    }
}
