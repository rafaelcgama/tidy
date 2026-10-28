import XCTest
@testable import TidyCore

final class QuarantineStoreTests: XCTestCase {
    var tmp: URL!
    var store: QuarantineStore!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = QuarantineStore(root: tmp.appendingPathComponent("Quarantine"), retentionDays: 30)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeItem(_ relative: String) throws -> ScanItem {
        let url = tmp.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: url)
        return ScanItem(url: url, size: 4, category: "cache", isSelected: true)
    }

    func testQuarantineMovesItemsAndRecordsThem() throws {
        let a = try makeItem("Caches/a.bin")
        let b = try makeItem("Caches/b.bin")
        let outcome = try store.quarantine([a, b])

        XCTAssertEqual(outcome.batch.entries.count, 2)
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.url.path))
        XCTAssertEqual(store.batches().map(\.id), [outcome.batch.id])

        let history = try String(contentsOf: store.root.appendingPathComponent("history.jsonl"), encoding: .utf8)
        XCTAssertEqual(history.split(separator: "\n").count, 2)
        XCTAssertTrue(history.contains("\"quarantined\""))
    }

    func testSameFileNameFromTwoFoldersDoesNotCollide() throws {
        let a = try makeItem("Caches/one/data.db")
        let b = try makeItem("Logs/two/data.db")
        let outcome = try store.quarantine([a, b])
        XCTAssertEqual(outcome.batch.entries.count, 2)
    }

    func testRestorePutsItemsBackAndRemovesTheBatch() throws {
        let a = try makeItem("Caches/dir/a.bin")
        let outcome = try store.quarantine([a])
        // The parent folder may be gone by the time the user restores.
        try FileManager.default.removeItem(at: tmp.appendingPathComponent("Caches/dir"))

        let result = try store.restore(batchID: outcome.batch.id)
        XCTAssertEqual(result.restored.count, 1)
        XCTAssertEqual(try String(contentsOf: a.url, encoding: .utf8), "junk")
        XCTAssertTrue(store.batches().isEmpty)
    }

    func testRestoreNeverOverwritesANewFile() throws {
        let a = try makeItem("Caches/a.bin")
        let outcome = try store.quarantine([a])
        try Data("new".utf8).write(to: a.url)

        let result = try store.restore(batchID: outcome.batch.id)
        XCTAssertTrue(result.restored.isEmpty)
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertEqual(try String(contentsOf: a.url, encoding: .utf8), "new")
        XCTAssertEqual(store.batches().first?.entries.count, 1, "the skipped item stays in quarantine")
    }

    func testPurgeDeletesOnlyExpiredBatches() throws {
        let old = try store.quarantine([try makeItem("Caches/old.bin")], now: Date().addingTimeInterval(-31 * 86_400))
        let fresh = try store.quarantine([try makeItem("Caches/new.bin")])

        let purged = try store.purgeExpired()
        XCTAssertEqual(purged.map(\.id), [old.batch.id])
        XCTAssertEqual(store.batches().map(\.id), [fresh.batch.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent(old.batch.id).path))

        let history = try String(contentsOf: store.root.appendingPathComponent("history.jsonl"), encoding: .utf8)
        XCTAssertTrue(history.contains("\"purged\""))
    }

    func testDeleteRemovesOneBatchForGoodAndLogsIt() throws {
        let gone = try store.quarantine([try makeItem("Caches/gone.bin")])
        let kept = try store.quarantine([try makeItem("Caches/kept.bin")])

        let deleted = try store.delete(batchID: gone.batch.id)
        XCTAssertEqual(deleted.entries.map(\.originalPath), gone.batch.entries.map(\.originalPath))
        XCTAssertEqual(store.batches().map(\.id), [kept.batch.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent(gone.batch.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("Caches/gone.bin").path), "not put back either")
        XCTAssertThrowsError(try store.restore(batchID: gone.batch.id))

        let history = try String(contentsOf: store.root.appendingPathComponent("history.jsonl"), encoding: .utf8)
        XCTAssertTrue(history.contains("\"deleted\""))
        XCTAssertTrue(history.contains("gone.bin"))
        XCTAssertThrowsError(try store.delete(batchID: gone.batch.id), "already gone")
    }

    func testRejectsBatchIDsThatEscapeTheQuarantine() {
        XCTAssertThrowsError(try store.restore(batchID: "../Caches"))
        XCTAssertThrowsError(try store.restore(batchID: ".."))
        XCTAssertThrowsError(try store.restore(batchID: ""))
        XCTAssertThrowsError(try store.delete(batchID: "../Caches"))
        XCTAssertThrowsError(try store.delete(batchID: ".."))
        XCTAssertThrowsError(try store.delete(batchID: ""))
    }

    func testDeleteIgnoresAManifestThatDoesNotMatchItsFolder() throws {
        let outcome = try store.quarantine([try makeItem("Caches/a.bin")])
        let other = try store.quarantine([try makeItem("Caches/b.bin")])
        // A folder named after one batch holding another's manifest is left alone.
        let folder = store.root.appendingPathComponent(outcome.batch.id)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("manifest.json"))
        try FileManager.default.copyItem(at: store.root.appendingPathComponent(other.batch.id).appendingPathComponent("manifest.json"),
                                         to: folder.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try store.delete(batchID: outcome.batch.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testPurgeIgnoresAManifestThatDoesNotMatchItsFolder() throws {
        let outcome = try store.quarantine([try makeItem("Caches/a.bin")], now: Date().addingTimeInterval(-40 * 86_400))
        let renamed = store.root.appendingPathComponent("tampered")
        try FileManager.default.moveItem(at: store.root.appendingPathComponent(outcome.batch.id), to: renamed)

        XCTAssertTrue(try store.purgeExpired().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
    }

    func testMoveFailureIsReportedAndOtherItemsStillMove() throws {
        let fileManager = FailingFileManager()
        let locked = try makeItem("Caches/locked.bin")
        let ok = try makeItem("Caches/ok.bin")
        fileManager.failingPaths = [locked.url.path]
        let store = QuarantineStore(root: tmp.appendingPathComponent("Q2"), fileManager: fileManager)

        let outcome = try store.quarantine([locked, ok])
        XCTAssertEqual(outcome.failed.map { $0.item.url }, [locked.url])
        XCTAssertEqual(outcome.batch.entries.map(\.originalPath), [ok.url.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: locked.url.path))
    }

    func testNothingMovedLeavesNoBatchBehind() throws {
        let fileManager = FailingFileManager()
        let locked = try makeItem("Caches/locked.bin")
        fileManager.failingPaths = [locked.url.path]
        let store = QuarantineStore(root: tmp.appendingPathComponent("Q3"), fileManager: fileManager)

        _ = try store.quarantine([locked])
        XCTAssertTrue(store.batches().isEmpty)
    }

    func testCleanerReportsTheBatchItCreated() async throws {
        let item = try makeItem("Caches/a.bin")
        let cleaner = QuarantineCleaner(store: store, safePaths: SafePaths(allowedRoots: [tmp.appendingPathComponent("Caches")], forbiddenRoots: []))
        let result = try await cleaner.clean([item], dryRun: false)
        XCTAssertEqual(result.batch?.entries.count, 1)
        XCTAssertEqual(result.freedBytes, 4)

        let dryRun = try await cleaner.clean([try makeItem("Caches/b.bin")], dryRun: true)
        XCTAssertNil(dryRun.batch)
        XCTAssertEqual(store.batches().count, 1)
    }
}

/// Simulates a file the user can't move (in use, or protected).
final class FailingFileManager: FileManager {
    var failingPaths: Set<String> = []

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if failingPaths.contains(srcURL.path) { throw CocoaError(.fileWriteNoPermission) }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}
