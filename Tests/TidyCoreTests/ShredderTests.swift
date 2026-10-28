import XCTest
@testable import TidyCore

final class ShredderTests: XCTestCase {
    var root: URL!
    var shredder: Shredder!

    override func setUpWithError() throws {
        let base = try XCTUnwrap(SecureFileOps.realPath(FileManager.default.temporaryDirectory.path))
        root = URL(fileURLWithPath: base).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        shredder = Shredder(forbidden: [root.appendingPathComponent("Keychains")],
                            refusedExactly: [root],
                            log: root.appendingPathComponent("Tidy/shred-log.jsonl"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ relative: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func exists(_ url: URL) -> Bool {
        SecureFileOps.entryInfo(url.path) != nil
    }

    func testOverwritingReplacesEveryByteWithoutChangingTheLength() throws {
        let original = Data(repeating: 0x41, count: (1 << 20) + 13)   // more than one buffer, and an odd tail
        let file = root.appendingPathComponent("secret.bin")
        try original.write(to: file)
        XCTAssertEqual(try Shredder.overwrite(file.path), Int64(original.count))
        let after = try Data(contentsOf: file)
        XCTAssertEqual(after.count, original.count)
        XCTAssertNotEqual(after, original)
        // Random bytes: no long run of the old content survives.
        XCTAssertLessThan(after.filter { $0 == 0x41 }.count, original.count / 100)
    }

    func testShredsFilesAndFoldersAndLogsIt() throws {
        let file = try write("letter.txt", "dear diary")
        let folder = root.appendingPathComponent("Old Taxes")
        try write("Old Taxes/2019.pdf", "numbers")
        try write("Old Taxes/receipts/a.jpg", "pixels")

        let plan = shredder.plan([file, folder])
        XCTAssertEqual(plan.accepted.map(\.path), [file.path, folder.path])
        XCTAssertEqual(plan.fileCount, 3)
        XCTAssertEqual(plan.folderCount, 2)
        XCTAssertEqual(plan.totalBytes, Int64("dear diary".utf8.count + "numbers".utf8.count + "pixels".utf8.count))

        var reported: Int64 = 0
        let result = try shredder.shred([file, folder]) { reported = $0 }
        XCTAssertEqual(result.shredded.map(\.path), [file.path, folder.path])
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertEqual(result.bytesOverwritten, plan.totalBytes)
        XCTAssertEqual(reported, plan.totalBytes)
        XCTAssertFalse(exists(file))
        XCTAssertFalse(exists(folder))
        // Nothing left behind under another name either.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["Tidy"])

        let log = try String(contentsOf: root.appendingPathComponent("Tidy/shred-log.jsonl"), encoding: .utf8)
        let lines = log.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("\"action\":\"start\""))
        XCTAssertTrue(lines[1].contains("\"action\":\"shredded\""))
        XCTAssertTrue(lines[1].contains("letter.txt"))
        XCTAssertFalse(log.contains("dear diary"), "the log never holds contents")
    }

    func testSymlinksAreRemovedButWhatTheyPointToIsLeftAlone() throws {
        let outside = try write("keep/important.txt", "keep me")
        let folder = root.appendingPathComponent("trash")
        try write("trash/junk.txt", "junk")
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link-to-important"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link-to-folder"),
                                                   withDestinationURL: outside.deletingLastPathComponent())
        let topLink = root.appendingPathComponent("shortcut")
        try FileManager.default.createSymbolicLink(at: topLink, withDestinationURL: outside)

        let result = try shredder.shred([folder, topLink])
        XCTAssertEqual(result.shredded.count, 2)
        XCTAssertFalse(exists(folder))
        XCTAssertFalse(exists(topLink))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep me")
    }

    func testRefusesHardLinkedFilesAndLeavesBothNames() throws {
        let file = try write("shared.txt", "two names")
        let other = root.appendingPathComponent("other-name.txt")
        try FileManager.default.linkItem(at: file, to: other)

        let result = try shredder.shred([file])
        XCTAssertTrue(result.shredded.isEmpty)
        XCTAssertTrue(result.failed.first?.reason.contains("hard links") == true)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "two names")
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "two names")
    }

    func testRefusesForbiddenAndTooBroadPaths() throws {
        let keychain = try write("Keychains/login.keychain-db", "secrets")
        let throughLink = root.appendingPathComponent("innocent")
        try FileManager.default.createSymbolicLink(at: throughLink, withDestinationURL: root.appendingPathComponent("Keychains"))

        XCTAssertEqual(shredder.refusal(for: keychain), "Tidy never touches this folder.")
        XCTAssertEqual(shredder.refusal(for: throughLink.appendingPathComponent("login.keychain-db")), "Tidy never touches this folder.",
                       "a path through a symlinked folder is judged by where it leads")
        XCTAssertTrue(shredder.refusal(for: root)?.hasPrefix("Too broad") == true)
        XCTAssertTrue(shredder.refusal(for: URL(fileURLWithPath: "/"))?.hasPrefix("Too broad") == true)
        XCTAssertTrue(shredder.refusal(for: root.appendingPathComponent("a/../")).map { $0.hasPrefix("Too broad") } == true)
        XCTAssertEqual(shredder.refusal(for: root.appendingPathComponent("missing")), "It isn't there any more.")

        let plan = shredder.plan([keychain, throughLink.appendingPathComponent("login.keychain-db")])
        XCTAssertTrue(plan.accepted.isEmpty)
        XCTAssertEqual(plan.refused.count, 2)
        let result = try shredder.shred([keychain, throughLink.appendingPathComponent("login.keychain-db")])
        XCTAssertTrue(result.shredded.isEmpty)
        XCTAssertEqual(result.failed.count, 2)
        XCTAssertEqual(try String(contentsOf: keychain, encoding: .utf8), "secrets")
    }

    func testRefusesFoldersHoldingWhatTidyNeverTouches() throws {
        let shredder = Shredder(forbidden: [root.appendingPathComponent("Library/Keychains")],
                                refusedExactly: [root],
                                log: root.appendingPathComponent("Tidy/shred-log.jsonl"))
        let library = root.appendingPathComponent("Library")
        let keychain = try write("Library/Keychains/login.keychain-db", "secrets")
        let cache = try write("Library/Caches/cache.bin", "junk")
        let pictures = root.appendingPathComponent("Pictures")
        let photos = try write("Pictures/Trip.photoslibrary/database/Photos.sqlite", "memories")
        let beach = try write("Pictures/beach.jpg", "sand")
        let wallet = try write("Downloads/old.keychain", "more secrets")
        // The same Library reached through a symlinked folder is judged by where its contents really are.
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let libraryThroughAlias = alias.appendingPathComponent("Library")

        let plan = shredder.plan([library, pictures, wallet, libraryThroughAlias])
        XCTAssertTrue(plan.accepted.isEmpty)
        XCTAssertEqual(plan.refused.map(\.url.path), [library.path, pictures.path, wallet.path, libraryThroughAlias.path])
        guard plan.refused.count == 4 else { return }
        XCTAssertTrue(plan.refused[0].reason.hasPrefix("It holds ") && plan.refused[0].reason.contains("Library/Keychains"))
        XCTAssertTrue(plan.refused[1].reason.contains("Trip.photoslibrary"))
        XCTAssertEqual(plan.refused[2].reason, "Tidy never touches Photos libraries or keychains.")
        XCTAssertTrue(plan.refused[3].reason.contains("Library/Keychains"))

        let result = try shredder.shred([library, pictures, wallet, libraryThroughAlias])
        XCTAssertTrue(result.shredded.isEmpty)
        XCTAssertEqual(result.failed.count, 4)
        XCTAssertEqual(result.bytesOverwritten, 0)
        // Nothing in them was touched, not even what could have been shredded on its own.
        for (url, text) in [(keychain, "secrets"), (cache, "junk"), (photos, "memories"), (beach, "sand"), (wallet, "more secrets")] {
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
        }
        // What's beside them can still be chosen.
        XCTAssertEqual(shredder.plan([cache, beach]).accepted.map(\.path), [cache.path, beach.path])
    }

    func testItemsInsideOtherChosenItemsCountOnce() throws {
        let folder = root.appendingPathComponent("box")
        let inner = try write("box/inner.txt", "x")
        let plan = shredder.plan([inner, folder, folder])
        XCTAssertEqual(plan.accepted.map(\.path), [folder.path])
        XCTAssertEqual(plan.fileCount, 1)
    }
}
