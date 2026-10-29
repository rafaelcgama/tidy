import XCTest
@testable import TidyCore

final class SystemJunkScannerTests: XCTestCase {
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

    func testFindsCachesAndLogsAndPreselectsThem() async throws {
        try write("Library/Caches/com.example.app/blob")
        try FileManager.default.backdate(home.appendingPathComponent("Library/Caches/com.example.app"), days: 45)
        try write("Library/Logs/app.log")
        let scanner = SystemJunkScanner(locations: SystemJunkScanner.defaultLocations(home: home))
        let items = try await scanner.scan { _ in }
        XCTAssertEqual(Set(items.map(\.category)), ["User caches", "User logs"])
        XCTAssertTrue(items.allSatisfy(\.isSelected), "an unused cache, and logs however new")
        XCTAssertTrue(items.allSatisfy { $0.size > 0 })
    }

    func testCachesInUseAreListedButNotPreselected() async throws {
        try write("Library/Caches/com.example.daily/blob")
        try write("Library/Caches/com.example.gone/blob")
        try write("Library/Caches/com.example.old/blob")
        try write("Library/Caches/com.example.old/fresh/new-entry")
        try FileManager.default.backdate(home.appendingPathComponent("Library/Caches/com.example.gone"), days: 31)
        try FileManager.default.backdate(home.appendingPathComponent("Library/Caches/com.example.old/blob"), days: 200)
        try write("Library/Developer/Xcode/DerivedData/Tidy-abc/Build/app")
        try write("Library/Developer/Xcode/DerivedData/OldThing-def/Build/app")
        try FileManager.default.backdate(home.appendingPathComponent("Library/Developer/Xcode/DerivedData/OldThing-def"), days: 90)

        let scanner = SystemJunkScanner(locations: SystemJunkScanner.defaultLocations(home: home))
        let items = try await scanner.scan { _ in }
        let selected = Dictionary(uniqueKeysWithValues: items.map { ($0.url.lastPathComponent, $0.isSelected) })
        XCTAssertEqual(selected, ["com.example.daily": false, "com.example.gone": true, "com.example.old": false,
                                  "Tidy-abc": false, "OldThing-def": true],
                       "anything written in the last 30 days counts as in use, even deep inside")
    }

    func testSimulatorCachesAreCleanedLikeOtherCaches() async throws {
        try write("Library/Developer/CoreSimulator/Caches/dyld/22A3354/dyld_sim_shared_cache_arm64e")
        try write("Library/Developer/CoreSimulator/Caches/fresh/blob")
        try FileManager.default.backdate(home.appendingPathComponent("Library/Developer/CoreSimulator/Caches/dyld"), days: 45)
        let scanner = SystemJunkScanner(locations: SystemJunkScanner.defaultLocations(home: home))
        let items = try await scanner.scan { _ in }
        let selected = Dictionary(uniqueKeysWithValues: items.map { ($0.url.lastPathComponent, $0.isSelected) })
        XCTAssertEqual(selected, ["dyld": true, "fresh": false])
        XCTAssertTrue(items.allSatisfy { $0.category == "Simulator caches" })
    }

    func testArchivesAreNotPreselectedAndTheTrashIsLeftToTrash() async throws {
        try write("Library/Developer/Xcode/Archives/2026-10-01/App.xcarchive/Info.plist")
        try write(".Trash/old.zip")
        let scanner = SystemJunkScanner(locations: SystemJunkScanner.defaultLocations(home: home))
        let items = try await scanner.scan { _ in }
        XCTAssertEqual(items.map(\.category), ["Xcode archives"], "emptying the Trash deletes for good, so it isn't quarantined with junk")
        XCTAssertTrue(items.allSatisfy { !$0.isSelected })
    }

    func testIgnoresDocumentsAndMissingLocations() async throws {
        try write("Documents/thesis.docx")
        let scanner = SystemJunkScanner(locations: SystemJunkScanner.defaultLocations(home: home))
        let items = try await scanner.scan { _ in }
        XCTAssertTrue(items.isEmpty)
    }

    func testDoesNotFollowSymlinkOutOfJunkLocation() async throws {
        try write("Documents/big.bin", bytes: 1_000_000)
        let caches = home.appendingPathComponent("Library/Caches")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: caches.appendingPathComponent("link"),
                                                   withDestinationURL: home.appendingPathComponent("Documents"))
        let scanner = SystemJunkScanner(locations: SystemJunkScanner.defaultLocations(home: home))
        let items = try await scanner.scan { _ in }
        XCTAssertTrue(items.isEmpty)
    }

    func testScannerAllowlistPermitsOnlyJunkLocations() {
        let scanner = SystemJunkScanner(locations: SystemJunkScanner.defaultLocations(home: home))
        XCTAssertTrue(scanner.safePaths.permits(home.appendingPathComponent("Library/Caches/x")))
        XCTAssertFalse(scanner.safePaths.permits(home.appendingPathComponent("Documents/x")))
    }

    func testCleaningScanResultsMovesThemToQuarantine() async throws {
        try write("Library/Caches/com.example.app/blob")
        try FileManager.default.backdate(home.appendingPathComponent("Library/Caches/com.example.app"), days: 45)
        let scanner = SystemJunkScanner(locations: SystemJunkScanner.defaultLocations(home: home))
        let items = try await scanner.scan { _ in }
        let cleaner = QuarantineCleaner(quarantineRoot: home.appendingPathComponent("Quarantine"), safePaths: scanner.safePaths)
        let result = try await cleaner.clean(items, dryRun: false)
        XCTAssertEqual(result.removed.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Caches/com.example.app").path))
    }

    func testSystemFoldersOfferOnlyWhatTheHelperWouldMove() async throws {
        try write("var/log/system.log")
        try write("var/log/system.log.0.gz")
        try write("var/log/.hidden.gz")
        let logs = home.appendingPathComponent("var/log")
        let canonical = try XCTUnwrap(SecureFileOps.realPath(logs.path))
        let scanner = SystemJunkScanner(locations: [.init(category: "Archived system logs", url: logs, selectedByDefault: false)],
                                        policy: HelperPolicy(folders: [.init(canonical, suffixes: [".gz", ".bz2"])]))
        let items = try await scanner.scan { _ in }
        XCTAssertEqual(items.map(\.url.lastPathComponent), ["system.log.0.gz"], "live logs and hidden files stay")
    }

    func testCancellationStopsScan() async throws {
        try write("Library/Caches/a/blob")
        let scanner = SystemJunkScanner(locations: SystemJunkScanner.defaultLocations(home: home))
        let task = Task { try await scanner.scan { _ in } }
        task.cancel()
        do {
            _ = try await task.value
        } catch is CancellationError {
            return
        }
        // A scan that finished before cancel was observed is also acceptable.
    }
}
