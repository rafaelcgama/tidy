import AppKit
import SwiftUI
import TidyCore

/// A collapsible category with a checkbox for the whole group and one per item.
struct ItemGroupRow: View {
    let group: CategorySummary
    let toggleItem: (ScanItem) -> Void
    let setCategory: (String, Bool) -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(group.items) { item in
                HStack {
                    Toggle("", isOn: Binding(get: { item.isSelected }, set: { _ in toggleItem(item) }))
                        .labelsHidden()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        // Where it is, so items with the same name (every project's node_modules) can be told apart.
                        Text(DisplayPath.folder(of: item.url))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .help(item.url.path)
                    Spacer()
                    Text(ByteFormat.string(item.size))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .contextMenu {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                }
            }
        } label: {
            HStack {
                Toggle("", isOn: Binding(get: { group.isFullySelected },
                                         set: { setCategory(group.category, $0) }))
                    .labelsHidden()
                Text(group.category)
                    .fontWeight(.medium)
                Spacer()
                Text("\(ByteFormat.string(group.selectedSize)) of \(ByteFormat.string(group.totalSize))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}
