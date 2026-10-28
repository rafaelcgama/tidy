import XCTest
@testable import TidyCore

final class TreemapTests: XCTestCase {
    let bounds = TreemapRect(x: 0, y: 0, width: 400, height: 300)

    private func intersectionArea(_ a: TreemapRect, _ b: TreemapRect) -> Double {
        let width = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
        let height = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
        return max(0, width) * max(0, height)
    }

    func testSingleValueFillsBounds() {
        let rect = Treemap.layout([42], in: bounds)[0]
        XCTAssertEqual(rect.x, 0, accuracy: 0.001)
        XCTAssertEqual(rect.y, 0, accuracy: 0.001)
        XCTAssertEqual(rect.width, bounds.width, accuracy: 0.001)
        XCTAssertEqual(rect.height, bounds.height, accuracy: 0.001)
    }

    func testAreasAreProportionalInsideBoundsAndDoNotOverlap() {
        let values: [Double] = [5, 60, 1, 12, 30, 7, 7, 3, 90, 2]
        let rects = Treemap.layout(values, in: bounds)
        let total = values.reduce(0, +)
        XCTAssertEqual(rects.count, values.count)

        for (value, rect) in zip(values, rects) {
            XCTAssertEqual(rect.area, bounds.area * value / total, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(rect.x, -0.001)
            XCTAssertGreaterThanOrEqual(rect.y, -0.001)
            XCTAssertLessThanOrEqual(rect.x + rect.width, bounds.width + 0.001)
            XCTAssertLessThanOrEqual(rect.y + rect.height, bounds.height + 0.001)
        }
        for i in rects.indices {
            for j in rects.indices where j > i {
                XCTAssertEqual(intersectionArea(rects[i], rects[j]), 0, accuracy: 0.01, "rects \(i) and \(j) overlap")
            }
        }
    }

    func testEqualValuesInASquareMakeSquares() {
        let rects = Treemap.layout([1, 1, 1, 1], in: TreemapRect(x: 0, y: 0, width: 100, height: 100))
        for rect in rects {
            XCTAssertEqual(rect.width, 50, accuracy: 0.001)
            XCTAssertEqual(rect.height, 50, accuracy: 0.001)
        }
    }

    func testZeroValuesGetEmptyRects() {
        let rects = Treemap.layout([0, 10, 0], in: bounds)
        XCTAssertEqual(rects[0].area, 0)
        XCTAssertEqual(rects[2].area, 0)
        XCTAssertEqual(rects[1].area, bounds.area, accuracy: 0.01)
        XCTAssertTrue(Treemap.layout([0, 0], in: bounds).allSatisfy { $0.area == 0 })
        XCTAssertTrue(Treemap.layout([], in: bounds).isEmpty)
    }
}

final class SizeTreeBuilderTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, bytes: Int) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
    }

    func testSizesAddUpAndChildrenAreLargestFirst() async throws {
        try write("big/a.bin", bytes: 200_000)
        try write("big/nested/b.bin", bytes: 100_000)
        try write("small.bin", bytes: 10_000)

        let tree = try await SizeTreeBuilder().build(at: root)
        XCTAssertEqual(tree.children.map(\.name), ["big", "small.bin"])
        XCTAssertEqual(tree.size, tree.children.reduce(0) { $0 + $1.size })
        let big = tree.children[0]
        XCTAssertTrue(big.isDirectory)
        XCTAssertEqual(big.children.map(\.name), ["a.bin", "nested"])
        XCTAssertGreaterThanOrEqual(big.size, 300_000)
    }

    func testMergesSmallEntriesBeyondTheLimit() async throws {
        for (index, size) in [50_000, 40_000, 30_000, 20_000, 10_000].enumerated() {
            try write("f\(index).bin", bytes: size)
        }
        let tree = try await SizeTreeBuilder(maxChildren: 2).build(at: root)
        XCTAssertEqual(tree.children.count, 3)
        XCTAssertEqual(tree.children.map(\.name).prefix(2), ["f0.bin", "f1.bin"])
        let aggregate = tree.children[2]
        XCTAssertTrue(aggregate.isAggregate)
        XCTAssertEqual(aggregate.itemCount, 3)
        XCTAssertEqual(tree.size, tree.children.reduce(0) { $0 + $1.size }, "merging keeps the total")
    }

    func testDoesNotFollowSymlinks() async throws {
        try write("data/a.bin", bytes: 100_000)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"),
                                                   withDestinationURL: root.appendingPathComponent("data"))
        let tree = try await SizeTreeBuilder().build(at: root)
        XCTAssertEqual(tree.children.map(\.name), ["data"])
    }

    func testStopsWhenCancelled() async throws {
        try write("a.bin", bytes: 10)
        let root = self.root!
        let task = Task { () -> DiskNode in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SizeTreeBuilder().build(at: root)
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }
    }
}
