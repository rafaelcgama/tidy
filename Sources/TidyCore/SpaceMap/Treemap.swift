import Foundation

public struct TreemapRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var area: Double { width * height }
}

public enum Treemap {
    /// Squarified treemap (Bruls, Huizing & van Wijk). Returns one rect per value, in input order;
    /// each rect's area is proportional to its value. Zero or negative values get an empty rect.
    public static func layout(_ values: [Double], in bounds: TreemapRect) -> [TreemapRect] {
        let empty = TreemapRect(x: bounds.x, y: bounds.y, width: 0, height: 0)
        var result = Array(repeating: empty, count: values.count)
        let total = values.filter { $0 > 0 }.reduce(0, +)
        guard total > 0, bounds.area > 0 else { return result }

        let scale = bounds.area / total
        let order = values.indices.filter { values[$0] > 0 }.sorted { values[$0] > values[$1] }
        let areas = values.map { max(0, $0) * scale }

        var remaining = bounds
        var row: [Int] = []
        var next = 0
        while next < order.count {
            let index = order[next]
            let side = min(remaining.width, remaining.height)
            if row.isEmpty || worstRatio(row + [index], areas: areas, side: side) <= worstRatio(row, areas: areas, side: side) {
                row.append(index)
                next += 1
            } else {
                remaining = place(row, areas: areas, in: remaining, into: &result)
                row = []
            }
        }
        if !row.isEmpty {
            _ = place(row, areas: areas, in: remaining, into: &result)
        }
        return result
    }

    /// The worst aspect ratio in a row laid along a side of length `side`.
    private static func worstRatio(_ row: [Int], areas: [Double], side: Double) -> Double {
        let rowAreas = row.map { areas[$0] }
        let sum = rowAreas.reduce(0, +)
        guard sum > 0, side > 0, let largest = rowAreas.max(), let smallest = rowAreas.min(), smallest > 0 else { return .infinity }
        let sideSquared = side * side
        return max(sideSquared * largest / (sum * sum), (sum * sum) / (sideSquared * smallest))
    }

    /// Lays a row along the shorter side of `rect` and returns the space left over.
    private static func place(_ row: [Int], areas: [Double], in rect: TreemapRect, into result: inout [TreemapRect]) -> TreemapRect {
        let sum = row.reduce(0) { $0 + areas[$1] }
        if rect.width >= rect.height {
            // A column on the left.
            let columnWidth = rect.height > 0 ? sum / rect.height : 0
            var y = rect.y
            for index in row {
                let height = columnWidth > 0 ? areas[index] / columnWidth : 0
                result[index] = TreemapRect(x: rect.x, y: y, width: columnWidth, height: height)
                y += height
            }
            return TreemapRect(x: rect.x + columnWidth, y: rect.y, width: max(0, rect.width - columnWidth), height: rect.height)
        } else {
            // A row along the top.
            let rowHeight = rect.width > 0 ? sum / rect.width : 0
            var x = rect.x
            for index in row {
                let width = rowHeight > 0 ? areas[index] / rowHeight : 0
                result[index] = TreemapRect(x: x, y: rect.y, width: width, height: rowHeight)
                x += width
            }
            return TreemapRect(x: rect.x, y: rect.y + rowHeight, width: rect.width, height: max(0, rect.height - rowHeight))
        }
    }
}
