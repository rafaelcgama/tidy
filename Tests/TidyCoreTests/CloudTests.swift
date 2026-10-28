import XCTest
@testable import TidyCore

final class CloudTests: XCTestCase {
    var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    @discardableResult
    private func write(_ relative: String, _ data: Data) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func bytes(_ count: Int, seed: UInt8) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 17) ^ seed })
    }

    func testFindsCloudFoldersWithReadableNames() throws {
        for folder in ["Library/Mobile Documents/com~apple~CloudDocs", "Library/CloudStorage/GoogleDrive-me@example.com",
                       "Library/CloudStorage/Dropbox", "Library/CloudStorage/OneDrive-Personal", "Library/CloudStorage/Box-Box"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let names = CloudStorage.folders(home: home).map(\.name)
        XCTAssertEqual(names, ["iCloud Drive", "Box", "Dropbox", "Google Drive (me@example.com)", "OneDrive (Personal)"])
    }

    func testNoCloudFoldersMeansNone() {
        XCTAssertTrue(CloudStorage.folders(home: home).isEmpty)
    }

    func testListsLargeCloudFilesAndWhetherTheyAreDownloaded() async throws {
        try write("Library/CloudStorage/Dropbox/video.mov", bytes(50_000, seed: 1))
        try write("Library/CloudStorage/Dropbox/note.txt", bytes(10, seed: 2))
        // A sparse file has no data on disk, like a cloud placeholder.
        let placeholder = home.appendingPathComponent("Library/CloudStorage/Dropbox/placeholder.zip")
        FileManager.default.createFile(atPath: placeholder.path, contents: nil)
        let handle = try FileHandle(forWritingTo: placeholder)
        try handle.truncate(atOffset: 80_000)
        try handle.close()

        let files = try await CloudStorage.largeFiles(in: CloudStorage.folders(home: home), minimumSize: 1000)
        XCTAssertEqual(files.map { $0.url.lastPathComponent }, ["placeholder.zip", "video.mov"])
        XCTAssertFalse(files[0].isDownloaded)
        XCTAssertTrue(files[1].isDownloaded)
        XCTAssertEqual(files[1].provider, "Dropbox")
    }

    func testFindsLocalCopiesOfCloudFilesOnly() async throws {
        let report = bytes(20_000, seed: 3)
        try write("Library/CloudStorage/Dropbox/Reports/q3.pdf", report)
        try write("Documents/q3 copy.pdf", report)
        try write("Documents/a.bin", bytes(20_000, seed: 4))           // local duplicates with no cloud copy
        try write("Desktop/a.bin", bytes(20_000, seed: 4))

        let finder = CloudCopyFinder(localRoots: [home.appendingPathComponent("Documents"), home.appendingPathComponent("Desktop")],
                                     cloudFolders: CloudStorage.folders(home: home), minimumSize: 1000)
        let copies = try await finder.find()
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(copies[0].cloudFile.url.lastPathComponent, "q3.pdf")
        XCTAssertEqual(copies[0].localCopies.map { $0.url.lastPathComponent }, ["q3 copy.pdf"])
    }

    func testCloudFilesAreNeverCleanable() {
        let cloud = CloudFolder(name: "Dropbox", url: home.appendingPathComponent("Library/CloudStorage/Dropbox"))
        let finder = CloudCopyFinder(localRoots: [home], cloudFolders: [cloud])
        XCTAssertFalse(finder.safePaths.permits(cloud.url.appendingPathComponent("q3.pdf")))
        XCTAssertTrue(finder.safePaths.permits(home.appendingPathComponent("Documents/q3 copy.pdf")))
    }

    func testPlaceholdersAreNeverReadForDuplicates() async throws {
        for name in ["one.zip", "two.zip"] {
            let url = home.appendingPathComponent("Library/CloudStorage/Dropbox/\(name)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 80_000)
            try handle.close()
        }
        let groups = try await DuplicateFinder(roots: [home], minimumSize: 1000).find()
        XCTAssertTrue(groups.isEmpty)
    }
}
