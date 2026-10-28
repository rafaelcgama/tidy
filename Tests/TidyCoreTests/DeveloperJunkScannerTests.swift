import XCTest
@testable import TidyCore

final class DeveloperJunkScannerTests: XCTestCase {
    var home: URL!
    var projects: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        projects = home.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
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

        let items = try await DeveloperJunkScanner(home: home, projectRoots: []).scan { _ in }
        XCTAssertEqual(names(items), ["Library/Caches/Homebrew", ".npm/_cacache", ".gradle/caches"])
        XCTAssertTrue(items.allSatisfy(\.isSelected))
    }

    func testCachesUsedLatelyStartUnselected() async throws {
        try write(".npm/_cacache/index-v5/aa")
        try write("Library/Caches/pip/http/old")
        try FileManager.default.backdate(home.appendingPathComponent("Library/Caches/pip"), days: 40)

        let items = try await DeveloperJunkScanner(home: home, projectRoots: []).scan { _ in }
        XCTAssertEqual(Set(items.filter(\.isSelected).map(\.category)), ["pip cache"])
        XCTAssertEqual(Set(items.filter { !$0.isSelected }.map(\.category)), ["npm cache"], "used today, so it stays unless you pick it")
        XCTAssertNotNil(items.first?.lastModified)
    }

    func testFindsBuildOutputOnlyNextToItsProjectFile() async throws {
        try write("Projects/web/package.json")
        try write("Projects/web/node_modules/react/index.js")
        try write("Projects/web/node_modules/react/node_modules/x/index.js")
        try write("Projects/rusty/Cargo.toml")
        try write("Projects/rusty/target/debug/app")
        try write("Projects/swifty/Package.swift")
        try write("Projects/swifty/.build/debug/app")
        try write("Projects/notes/target/plan.md")              // no Cargo.toml: someone's folder named target
        try write("Projects/loose/node_modules/thing.js")       // no package.json

        let items = try await DeveloperJunkScanner(home: home, projectRoots: [projects]).scan { _ in }
        XCTAssertEqual(names(items), ["Projects/web/node_modules", "Projects/rusty/target", "Projects/swifty/.build"])
        XCTAssertTrue(items.allSatisfy { !$0.isSelected }, "projects may be in use")
    }

    func testAllowlistCoversOnlyCachesAndChosenProjects() {
        let safe = DeveloperJunkScanner(home: home, projectRoots: [projects]).safePaths
        XCTAssertTrue(safe.permits(home.appendingPathComponent(".npm/_cacache/x")))
        XCTAssertTrue(safe.permits(projects.appendingPathComponent("web/node_modules")))
        XCTAssertFalse(safe.permits(home.appendingPathComponent(".npm/other")))
        XCTAssertFalse(safe.permits(home.appendingPathComponent("Documents/x")))
    }

    func testCleaningMovesBuildOutputToQuarantine() async throws {
        try write("Projects/web/package.json")
        try write("Projects/web/node_modules/react/index.js")
        let scanner = DeveloperJunkScanner(home: home, projectRoots: [projects])
        var items = try await scanner.scan { _ in }
        items = items.map { var item = $0; item.isSelected = true; return item }

        let store = QuarantineStore(root: home.appendingPathComponent("Quarantine"))
        let result = try await QuarantineCleaner(store: store, safePaths: scanner.safePaths).clean(items, dryRun: false)
        XCTAssertEqual(result.removed.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projects.appendingPathComponent("web/node_modules").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projects.appendingPathComponent("web/package.json").path))
    }
}
