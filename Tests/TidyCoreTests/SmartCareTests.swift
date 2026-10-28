import XCTest
@testable import TidyCore

/// A scanner that returns fixed items, for testing how Smart Care combines results.
private struct FixedScanner: CleaningScanner {
    let name: String
    let items: [ScanItem]
    let safePaths: SafePaths

    func scan(progress: @Sendable (ScanProgress) -> Void) async throws -> [ScanItem] { items }
}

final class SmartCareTests: XCTestCase {
    private func item(_ path: String, size: Int64 = 10, selected: Bool = true) -> ScanItem {
        ScanItem(url: URL(fileURLWithPath: path), size: size, category: "x", isSelected: selected)
    }

    func testCombinesScannersAndRemovesOverlaps() async throws {
        let junk = FixedScanner(name: "Junk", items: [item("/home/me/Library/Caches", size: 500)],
                                safePaths: SafePaths(allowedRoots: [URL(fileURLWithPath: "/home/me/Library/Caches")], forbiddenRoots: []))
        let developer = FixedScanner(name: "Dev", items: [item("/home/me/Library/Caches/Homebrew", size: 300),
                                                          item("/home/me/.npm/_cacache", size: 200)],
                                     safePaths: SafePaths(allowedRoots: [URL(fileURLWithPath: "/home/me/.npm/_cacache")], forbiddenRoots: []))
        let finding = Finding(url: URL(fileURLWithPath: "/x.plist"), title: "x", severity: .warning, reasons: ["r"])
        let report = try await SmartCare(cleanupScanners: [junk, developer], audit: { [finding] }).run()

        XCTAssertEqual(report.cleanup.map(\.url.path), ["/home/me/Library/Caches", "/home/me/.npm/_cacache"])
        XCTAssertEqual(report.findings.count, 1)
        XCTAssertTrue(report.safePaths.permits(URL(fileURLWithPath: "/home/me/.npm/_cacache/x")))
        XCTAssertTrue(report.safePaths.permits(URL(fileURLWithPath: "/home/me/Library/Caches/y")))
        XCTAssertFalse(report.safePaths.permits(URL(fileURLWithPath: "/home/me/Documents/z")))
    }

    func testOnlyPreselectedItemsAreCleanedByDefault() async throws {
        let scanner = FixedScanner(name: "Junk", items: [item("/a/caches", selected: true), item("/a/trash", selected: false)],
                                   safePaths: SafePaths(allowedRoots: [URL(fileURLWithPath: "/a")], forbiddenRoots: []))
        let report = try await SmartCare(cleanupScanners: [scanner], audit: { [] }).run()
        XCTAssertEqual(report.selectedCleanup.map(\.url.path), ["/a/caches"])
    }

    func testOverlapKeepsTheFirstOfTwoIdenticalPaths() {
        let first = item("/a/b", size: 1)
        let second = item("/a/b", size: 2)
        XCTAssertEqual(SmartCare.withoutOverlaps([first, second]).map(\.id), [first.id])
        XCTAssertEqual(SmartCare.withoutOverlaps([item("/a/bc"), item("/a/b")]).count, 2, "a sibling with a longer name is not inside")
    }

    func testStandardRunFindsJunkInAFakeHome() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Caches/com.example/blob")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: cache)
        try FileManager.default.backdate(cache.deletingLastPathComponent(), days: 45)

        let report = try await SmartCare.standard(home: home, systemLocations: []).run()
        XCTAssertEqual(report.selectedCleanup.count, 1)
        XCTAssertTrue(report.safePaths.permits(cache))
    }
}
