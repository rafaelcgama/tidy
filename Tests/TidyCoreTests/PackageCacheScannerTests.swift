import XCTest
@testable import TidyCore

final class PackageCacheScannerTests: XCTestCase {
    var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ relative: String, bytes: Int = 4096) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
    }

    private func names(_ items: [ScanItem]) -> Set<String> {
        let root = home.resolvingSymlinksInPath().path + "/"
        return Set(items.map { $0.url.resolvingSymlinksInPath().path.replacingOccurrences(of: root, with: "") })
    }

    func testFindsPackageManagerCachesAndPreselectsThem() async throws {
        try write("Library/Caches/Homebrew/downloads/pkg.tar.gz")
        try write(".npm/_cacache/index-v5/aa")
        try write(".gradle/caches/modules-2/x.jar")
        try write(".npm/other/keep.txt")
        for cache in ["Library/Caches/Homebrew", ".npm/_cacache", ".gradle/caches"] {
            try FileManager.default.backdate(home.appendingPathComponent(cache), days: 60)
        }

        let items = try await PackageCacheScanner(home: home).scan { _ in }
        XCTAssertEqual(names(items), ["Library/Caches/Homebrew", ".npm/_cacache", ".gradle/caches"])
        XCTAssertTrue(items.allSatisfy(\.isSelected))
    }

    func testCachesUsedLatelyStartUnselected() async throws {
        try write(".npm/_cacache/index-v5/aa")
        try write("Library/Caches/pip/http/old")
        try FileManager.default.backdate(home.appendingPathComponent("Library/Caches/pip"), days: 40)

        let items = try await PackageCacheScanner(home: home).scan { _ in }
        XCTAssertEqual(Set(items.filter(\.isSelected).map(\.category)), ["pip cache"])
        XCTAssertEqual(Set(items.filter { !$0.isSelected }.map(\.category)), ["npm cache"], "used today, so it stays unless you pick it")
        XCTAssertNotNil(items.first?.lastModified)
    }

    func testAllowlistCoversOnlyTheCaches() {
        let safe = PackageCacheScanner(home: home).safePaths
        XCTAssertTrue(safe.permits(home.appendingPathComponent(".npm/_cacache/x")))
        XCTAssertFalse(safe.permits(home.appendingPathComponent(".npm/other")))
        XCTAssertFalse(safe.permits(home.appendingPathComponent("Projects/web/node_modules")))
    }
}
