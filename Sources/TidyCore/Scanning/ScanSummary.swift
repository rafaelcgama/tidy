import Foundation

/// The items of one category, for display.
public struct CategorySummary: Identifiable, Sendable {
    public let category: String
    public let items: [ScanItem]

    public var id: String { category }
    public var totalSize: Int64 { items.totalSize }
    public var selectedSize: Int64 { items.selectedSize }
    public var isFullySelected: Bool { !items.isEmpty && items.allSatisfy(\.isSelected) }
}

public extension Array where Element == ScanItem {
    /// Groups by category, largest category first, largest item first within each.
    func groupedByCategory() -> [CategorySummary] {
        Dictionary(grouping: self, by: \.category)
            .map { CategorySummary(category: $0.key, items: $0.value.sorted { $0.size > $1.size }) }
            .sorted { ($0.totalSize, $1.category) > ($1.totalSize, $0.category) }
    }

    var totalSize: Int64 { reduce(0) { $0 + $1.size } }
    var selectedSize: Int64 { filter(\.isSelected).totalSize }
}
