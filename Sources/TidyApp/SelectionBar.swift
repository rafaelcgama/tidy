import SwiftUI
import TidyCore

/// The bar under a list of ticked items, as in Quarantine: Select All, what's ticked, and buttons for the
/// ticked items and for all of them.
struct SelectionBar<Actions: View>: View {
    let allSelected: Bool
    let summary: String
    let selectAll: (Bool) -> Void
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack {
            Button(allSelected ? "Deselect All" : "Select All") { selectAll(!allSelected) }
            Text(summary)
                .foregroundStyle(.secondary)
            Spacer()
            actions
        }
    }
}

extension Array where Element == ScanItem {
    /// What the bar says about the ticked items: "Tick the items to clean." or "3 items selected, 12 MB".
    func selectionSummary(verb: String) -> String {
        if isEmpty { return "Tick the items to \(verb)." }
        return (count == 1 ? "1 item" : "\(count) items") + " selected, \(ByteFormat.string(totalSize))"
    }
}
