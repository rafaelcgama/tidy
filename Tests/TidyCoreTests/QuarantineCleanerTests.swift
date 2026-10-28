import XCTest
@testable import TidyCore

final class QuarantineCleanerTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeFile(_ name: String, in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    func testDryRunLeavesFilesInPlace() async throws {
        let allowed = tmp.appendingPathComponent("caches")
        let file = try makeFile("a.cache", in: allowed)
        let cleaner = QuarantineCleaner(quarantineRoot: tmp.appendingPathComponent("q"),
                                        safePaths: SafePaths(allowedRoots: [allowed], forbiddenRoots: []))
        let result = try await cleaner.clean([ScanItem(url: file, size: 1, category: "cache", isSelected: true)], dryRun: true)
        XCTAssertEqual(result.removed.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testMovesSelectedFileToQuarantine() async throws {
        let allowed = tmp.appendingPathComponent("caches")
        let file = try makeFile("a.cache", in: allowed)
        let cleaner = QuarantineCleaner(quarantineRoot: tmp.appendingPathComponent("q"),
                                        safePaths: SafePaths(allowedRoots: [allowed], forbiddenRoots: []))
        let result = try await cleaner.clean([ScanItem(url: file, size: 1, category: "cache", isSelected: true)], dryRun: false)
        XCTAssertEqual(result.removed.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testSkipsUnselectedItems() async throws {
        let allowed = tmp.appendingPathComponent("caches")
        let file = try makeFile("a.cache", in: allowed)
        let cleaner = QuarantineCleaner(quarantineRoot: tmp.appendingPathComponent("q"),
                                        safePaths: SafePaths(allowedRoots: [allowed], forbiddenRoots: []))
        let result = try await cleaner.clean([ScanItem(url: file, size: 1, category: "cache")], dryRun: false)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testRefusesPathOutsideAllowlist() async throws {
        let allowed = tmp.appendingPathComponent("caches")
        let outside = try makeFile("doc.txt", in: tmp.appendingPathComponent("Documents"))
        let cleaner = QuarantineCleaner(quarantineRoot: tmp.appendingPathComponent("q"),
                                        safePaths: SafePaths(allowedRoots: [allowed], forbiddenRoots: []))
        let result = try await cleaner.clean([ScanItem(url: outside, size: 1, category: "x", isSelected: true)], dryRun: false)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testForbiddenRootWinsOverAllowedRoot() {
        let root = tmp.appendingPathComponent("Library")
        let keychains = root.appendingPathComponent("Keychains")
        let safe = SafePaths(allowedRoots: [root], forbiddenRoots: [keychains])
        XCTAssertFalse(safe.permits(keychains.appendingPathComponent("login.keychain-db")))
        XCTAssertTrue(safe.permits(root.appendingPathComponent("Caches/x")))
    }

    func testPrefixLookalikeIsNotInsideRoot() {
        let allowed = tmp.appendingPathComponent("caches")
        let safe = SafePaths(allowedRoots: [allowed], forbiddenRoots: [])
        XCTAssertFalse(safe.permits(tmp.appendingPathComponent("caches-evil/file")))
    }
}
