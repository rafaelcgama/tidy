import XCTest
@testable import TidyCore

final class ScanSummaryTests: XCTestCase {
    func testGroupsByCategoryLargestFirst() {
        let items = [
            ScanItem(url: URL(fileURLWithPath: "/a"), size: 10, category: "Logs", isSelected: true),
            ScanItem(url: URL(fileURLWithPath: "/b"), size: 300, category: "Caches", isSelected: false),
            ScanItem(url: URL(fileURLWithPath: "/c"), size: 5, category: "Logs", isSelected: false),
        ]
        let groups = items.groupedByCategory()
        XCTAssertEqual(groups.map(\.category), ["Caches", "Logs"])
        XCTAssertEqual(groups[1].items.map(\.size), [10, 5])
        XCTAssertEqual(groups[1].selectedSize, 10)
        XCTAssertFalse(groups[1].isFullySelected)
        XCTAssertEqual(items.selectedSize, 10)
        XCTAssertEqual(items.totalSize, 315)
    }

    func testEqualSizedCategoriesAreOrderedByName() {
        let items = [
            ScanItem(url: URL(fileURLWithPath: "/a"), size: 1, category: "Zeta"),
            ScanItem(url: URL(fileURLWithPath: "/b"), size: 1, category: "Alpha"),
        ]
        XCTAssertEqual(items.groupedByCategory().map(\.category), ["Alpha", "Zeta"])
    }
}
