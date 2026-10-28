import XCTest
@testable import TidyCore

final class ClutterTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ relative: String, _ data: Data, modified: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    private func bytes(_ count: Int, seed: UInt8) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) ^ seed })
    }

    private func paths(_ group: DuplicateGroup) -> Set<String> {
        Set(group.files.map { $0.url.lastPathComponent })
    }

    /// Paths inside the test folder, whichever of its paths (/var or /private/var on macOS) they use.
    private func relativePaths(_ group: DuplicateGroup) throws -> Set<String> {
        Set(try group.files.map { file in
            let path = file.url.path
            let range = try XCTUnwrap(path.range(of: "/" + root.lastPathComponent + "/"))
            return String(path[range.upperBound...])
        })
    }

    // MARK: Duplicates

    func testFindsCopiesAndIgnoresLookalikes() async throws {
        let content = bytes(3000, seed: 1)
        try write("a.bin", content)
        try write("sub/b.bin", content)
        var different = content
        different[2999] ^= 0xFF
        try write("c.bin", different)                      // same size, different last byte
        try write("d.bin", bytes(4000, seed: 1))           // different size
        try write(".hidden.bin", content)                  // hidden files are skipped

        let groups = try await DuplicateFinder(roots: [root], minimumSize: 1).find()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(paths(groups[0]), ["a.bin", "b.bin"])
        XCTAssertTrue(groups[0].files.allSatisfy { !$0.isSelected }, "nothing is preselected")
    }

    func testFilesThatOnlyDifferInTheMiddleAreNotDuplicates() async throws {
        let content = bytes(300_000, seed: 2)
        var middle = content
        middle[150_000] ^= 0xFF
        try write("x.bin", content)
        try write("y.bin", middle)
        XCTAssertEqual(try ContentHasher.quickHash(of: root.appendingPathComponent("x.bin"), size: 300_000),
                       try ContentHasher.quickHash(of: root.appendingPathComponent("y.bin"), size: 300_000))
        let groups = try await DuplicateFinder(roots: [root], minimumSize: 1).find()
        XCTAssertTrue(groups.isEmpty)
    }

    func testHardLinksAreNotDuplicates() async throws {
        let original = try write("a.bin", bytes(2000, seed: 3))
        try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("link.bin"))
        let groups = try await DuplicateFinder(roots: [root], minimumSize: 1).find()
        XCTAssertTrue(groups.isEmpty)
    }

    func testMinimumSizeSkipsSmallFiles() async throws {
        try write("a.bin", bytes(100, seed: 4))
        try write("b.bin", bytes(100, seed: 4))
        let groups = try await DuplicateFinder(roots: [root], minimumSize: 1000).find()
        XCTAssertTrue(groups.isEmpty)
    }

    func testOldestCopyComesFirstAndIsKeptByDefault() async throws {
        let content = bytes(5000, seed: 5)
        try write("new.bin", content, modified: Date())
        try write("old.bin", content, modified: Date().addingTimeInterval(-86_400 * 10))
        let groups = try await DuplicateFinder(roots: [root], minimumSize: 1).find()
        XCTAssertEqual(groups[0].files.first?.url.lastPathComponent, "old.bin")

        let selected = DuplicateFinder.selectAllButOldest(groups)
        XCTAssertEqual(selected, [groups[0].files[1].id])
        XCTAssertTrue(DuplicateFinder.groupsLosingEveryCopy(groups, selected: selected).isEmpty)
        let everything = Set(groups[0].files.map(\.id))
        XCTAssertEqual(DuplicateFinder.groupsLosingEveryCopy(groups, selected: everything).count, 1)
    }

    func testWastedBytesCountsAllButOneCopy() async throws {
        let content = bytes(8192, seed: 6)
        for name in ["1.bin", "2.bin", "3.bin"] { try write(name, content) }
        let group = try await DuplicateFinder(roots: [root], minimumSize: 1).find()[0]
        XCTAssertEqual(group.files.count, 3)
        XCTAssertEqual(group.wastedBytes, group.files[1].size + group.files[2].size)
    }

    func testHashDoesNotDependOnChunkBoundaries() {
        let data = bytes(1001, seed: 7)
        var whole = ContentHash()
        whole.update(data)
        var pieces = ContentHash()
        pieces.update(data.subdata(in: 0..<3))
        pieces.update(data.subdata(in: 3..<500))
        pieces.update(data.subdata(in: 500..<1001))
        XCTAssertEqual(whole.finalize(), pieces.finalize())

        var other = ContentHash()
        other.update(bytes(1001, seed: 8))
        XCTAssertNotEqual(whole.finalize(), other.finalize())
    }

    func testDuplicatesCanBeCleanedIntoQuarantine() async throws {
        let content = bytes(4096, seed: 9)
        try write("keep.bin", content, modified: Date().addingTimeInterval(-1000))
        let copy = try write("copy.bin", content)
        let finder = DuplicateFinder(roots: [root], minimumSize: 1)
        let groups = try await finder.find()
        let selected = DuplicateFinder.selectAllButOldest(groups)
        let items = groups.flatMap(\.files).map { item -> ScanItem in
            var item = item
            item.isSelected = selected.contains(item.id)
            return item
        }
        let store = QuarantineStore(root: root.appendingPathComponent(".quarantine"))
        let result = try await QuarantineCleaner(store: store, safePaths: finder.safePaths).clean(items, dryRun: false)
        XCTAssertEqual(result.removed.map { $0.url.lastPathComponent }, ["copy.bin"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("keep.bin").path))
    }

    func testGroupsNameTheirCopiesOnlyWhenTheNamesMatch() async throws {
        let song = bytes(3000, seed: 15)
        try write("a/song.mp3", song)
        try write("b/song.mp3", song)
        let invoice = bytes(4000, seed: 16)
        try write("c/invoice.pdf", invoice)
        try write("d/invoice copy.pdf", invoice)
        let groups = try await DuplicateFinder(roots: [root], minimumSize: 1).find()
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(Set(groups.map(\.sharedName)), ["song.mp3", nil])
    }

    // MARK: Folders left out

    func testDuplicatesLeaveOutAppDataAndProjectDependencies() async throws {
        let content = bytes(3000, seed: 17)
        try write("Documents/report.pdf", content)
        try write("Library/Mobile Documents/com~apple~CloudDocs/report.pdf", content)  // iCloud Drive: the user's own
        try write("Library/Caches/com.example.app/blob", content)
        try write("Library/Application Support/Example/report.pdf", content)
        try write("Library/report.pdf", content)
        try write("Projects/site/package.json", Data("{}".utf8))
        try write("Projects/site/node_modules/pdf-kit/report.pdf", content)
        try write("Projects/tool/Cargo.toml", Data("[package]".utf8))
        try write("Projects/tool/target/debug/report.pdf", content)
        try write("Projects/target/report.pdf", content)  // just a folder named target, not build output

        let groups = try await DuplicateFinder(roots: [root], minimumSize: 1, skipping: SkippedFolders(home: root)).find()
        XCTAssertEqual(groups.count, 1)
        guard let group = groups.first else { return }
        XCTAssertEqual(try relativePaths(group), ["Documents/report.pdf",
                                                  "Library/Mobile Documents/com~apple~CloudDocs/report.pdf",
                                                  "Projects/target/report.pdf"])
    }

    func testAChosenFolderIsSearchedInFull() async throws {
        let content = bytes(3000, seed: 18)
        try write("Library/Caches/a/blob", content)
        try write("Library/Caches/b/blob", content)
        try write("Projects/site/package.json", Data("{}".utf8))
        try write("Projects/site/node_modules/a/blob", content)
        try write("Projects/site/node_modules/b/node_modules/a/blob", content)
        let skipping = SkippedFolders(home: root)

        let library = try await DuplicateFinder(roots: [root.appendingPathComponent("Library")], minimumSize: 1, skipping: skipping).find()
        XCTAssertEqual(library.map(\.files.count), [2])
        let modules = try await DuplicateFinder(roots: [root.appendingPathComponent("Projects/site/node_modules")], minimumSize: 1,
                                                skipping: skipping).find()
        XCTAssertEqual(modules.map(\.files.count), [2])
        let home = try await DuplicateFinder(roots: [root], minimumSize: 1, skipping: skipping).find()
        XCTAssertTrue(home.isEmpty)
    }

    func testLargeFilesLeaveOutAppDataToo() async throws {
        try write("Movies/trip.mov", bytes(5000, seed: 19))
        try write("Library/Containers/com.example/Data/disk.img", bytes(5000, seed: 20))
        try write("Projects/app/Podfile", Data("platform :ios".utf8))
        try write("Projects/app/Pods/Big/Big.framework.zip", bytes(5000, seed: 21))
        let items = try await LargeFileFinder(roots: [root], minimumSize: 1000, skipping: SkippedFolders(home: root)).scan { _ in }
        XCTAssertEqual(items.map { $0.url.lastPathComponent }, ["trip.mov"])
    }

    func testPathsShowTheHomeFolderAsTilde() {
        let home = URL(fileURLWithPath: "/Users/me")
        XCTAssertEqual(DisplayPath.folder(of: URL(fileURLWithPath: "/Users/me/Projects/site/node_modules"), home: home), "~/Projects/site")
        XCTAssertEqual(DisplayPath.folder(of: URL(fileURLWithPath: "/Users/me/notes.txt"), home: home), "~")
        XCTAssertEqual(DisplayPath.string(URL(fileURLWithPath: "/Users/menu/a"), home: home), "/Users/menu/a")
        XCTAssertEqual(DisplayPath.folder(of: URL(fileURLWithPath: "/Volumes/Disk/a.bin"), home: home), "/Volumes/Disk")
    }

    // MARK: Large & old files

    func testLargeFilesAreGroupedByAgeAndSizeAndNotPreselected() async throws {
        let now = Date()
        try write("recent.bin", bytes(5000, seed: 10), modified: now.addingTimeInterval(-86_400))
        try write("ancient.bin", bytes(5000, seed: 11), modified: now.addingTimeInterval(-86_400 * 400))
        try write("small.bin", bytes(10, seed: 12))

        let items = try await LargeFileFinder(roots: [root], minimumSize: 1000, now: now).scan { _ in }
        XCTAssertEqual(Set(items.map { $0.url.lastPathComponent }), ["recent.bin", "ancient.bin"])
        let ancient = try XCTUnwrap(items.first { $0.url.lastPathComponent == "ancient.bin" })
        XCTAssertEqual(ancient.category, "Not changed in over 365 days")
        XCTAssertNotNil(ancient.lastModified)
        XCTAssertTrue(items.allSatisfy { !$0.isSelected })
    }

    func testWalkerNeverEntersForbiddenFolders() throws {
        try write("Library/Keychains/login.keychain-db", bytes(100, seed: 13))
        try write("Library/Caches/cache.bin", bytes(100, seed: 14))
        let files = try FileWalker.files(under: [root], minimumSize: 1,
                                         forbidden: [root.appendingPathComponent("Library/Keychains")]) { _ in }
        XCTAssertEqual(files.map { $0.url.lastPathComponent }, ["cache.bin"])
    }
}
