import XCTest
@testable import TidyCore

final class SimilarPhotosTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A smooth synthetic photo. Coordinates are relative, so a bigger copy shows the same picture.
    private func photo(width: Int, height: Int, seed: Double, brightness: Int = 0, noise: Int = 0) -> GrayImage {
        var state: UInt32 = 12345
        var pixels: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                let u = Double(x) / Double(width), v = Double(y) / Double(height)
                var value = 128 + 45 * sin(u * 7 + seed) + 35 * cos(v * 5 + seed * 1.7) + 15 * sin((u + v) * 11 + seed * 0.3)
                value += Double(brightness)
                if noise > 0 {
                    state = state &* 1_664_525 &+ 1_013_904_223
                    value += Double(Int(state >> 16) % (2 * noise + 1) - noise)
                }
                pixels.append(UInt8(max(0, min(255, value))))
            }
        }
        return GrayImage(width: width, height: height, pixels: pixels)!
    }

    private func uniform(_ value: UInt8, width: Int = 160, height: Int = 120) -> GrayImage {
        GrayImage(width: width, height: height, pixels: Array(repeating: value, count: width * height))!
    }

    /// Test photos are binary PGM files ("P5"), which need no image library.
    @discardableResult
    private func write(_ relative: String, _ image: GrayImage) throws -> URL {
        var data = Data("P5\n\(image.width) \(image.height)\n255\n".utf8)
        data.append(contentsOf: image.pixels)
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private let decodePGM: @Sendable (URL) -> DecodedPhoto? = { url in
        guard let data = try? Data(contentsOf: url) else { return nil }
        var newlines = 0
        guard let end = data.firstIndex(where: { byte in
            if byte == 0x0A { newlines += 1 }
            return newlines == 3
        }) else { return nil }
        let header = String(decoding: data[..<end], as: UTF8.self).split(whereSeparator: \.isWhitespace)
        guard header.count == 4, header[0] == "P5", let width = Int(header[1]), let height = Int(header[2]),
              let image = GrayImage(width: width, height: height, pixels: Array(data[(end + 1)...]))
        else { return nil }
        return DecodedPhoto(preview: image, pixelWidth: width, pixelHeight: height)
    }

    private func hash(_ image: GrayImage) throws -> PerceptualHash {
        try XCTUnwrap(PerceptualHash(image))
    }

    // MARK: Hashing

    func testResizeAveragesTheBlockEachPixelCovers() {
        let image = GrayImage(width: 4, height: 2, pixels: [10, 20, 30, 40, 50, 60, 70, 80])!
        XCTAssertEqual(image.resized(width: 2, height: 1).pixels, [35, 55])
        XCTAssertEqual(GrayImage(width: 1, height: 1, pixels: [7])!.resized(width: 3, height: 2).pixels, [7, 7, 7, 7, 7, 7])
        XCTAssertNil(GrayImage(width: 2, height: 2, pixels: [1, 2, 3]), "pixel count must match the size")
    }

    func testGradientsSetEveryBitOrNone() throws {
        let rising = GrayImage(width: 90, height: 80, pixels: (0..<80).flatMap { _ in (0..<90).map { UInt8($0 * 2) } })!
        let falling = GrayImage(width: 90, height: 80, pixels: rising.pixels.map { 200 - $0 })!
        XCTAssertEqual(try hash(rising).horizontal, 0)
        XCTAssertEqual(try hash(falling).horizontal, .max)
        XCTAssertEqual(try hash(rising).vertical, 0, "rows are identical, so no pixel is brighter than the one below")
        XCTAssertEqual(try hash(rising).distance(to: hash(falling)), 64)
    }

    func testCopiesHashCloseAndDifferentPhotosHashFar() throws {
        let original = try hash(photo(width: 160, height: 120, seed: 1))
        let edited = try hash(photo(width: 320, height: 240, seed: 1, brightness: 15, noise: 6))
        let other = try hash(photo(width: 160, height: 120, seed: 4))
        XCTAssertLessThanOrEqual(original.distance(to: edited), 4)
        XCTAssertGreaterThan(original.distance(to: other), 16)
    }

    func testBlankImagesHaveNoHash() {
        XCTAssertNil(PerceptualHash(uniform(200)))
        XCTAssertNil(PerceptualHash(uniform(0)))
        XCTAssertNotNil(PerceptualHash(photo(width: 40, height: 30, seed: 2)))
    }

    // MARK: Grouping

    func testClustersJoinChainsAndLeaveOutLoners() throws {
        let bits: [UInt64] = [0, 0b111, 0b111_111, .max, .max ^ 1, 0xF0F0_F0F0_F0F0_F0F0]
        let hashes = bits.map { PerceptualHash(horizontal: $0, vertical: $0) }
        XCTAssertEqual(try SimilarPhotoFinder.clusters(hashes, maxDistance: 3), [[0, 1, 2], [3, 4]])
        XCTAssertEqual(try SimilarPhotoFinder.clusters(hashes, maxDistance: 2), [[3, 4]])
        XCTAssertEqual(try SimilarPhotoFinder.clusters([], maxDistance: 8), [])
    }

    func testFindsSimilarPhotosBestFirst() async throws {
        try write("Trip/IMG_1.pgm", photo(width: 160, height: 120, seed: 1))
        try write("Trip/IMG_1 small.pgm", photo(width: 80, height: 60, seed: 1, brightness: 10, noise: 4))
        try write("Other/IMG_2.pgm", photo(width: 160, height: 120, seed: 4))
        try write("blank.pgm", uniform(250))
        try write("blank copy.pgm", uniform(250))                       // blank images never match
        try write("tiny.pgm", photo(width: 8, height: 6, seed: 1))       // under the minimum size
        try write("notes.txt", photo(width: 160, height: 120, seed: 1))  // not an image extension
        try write(".hidden.pgm", photo(width: 160, height: 120, seed: 1))

        let finder = SimilarPhotoFinder(roots: [root], minimumSize: 1000, extensions: ["pgm"], decode: decodePGM)
        let groups = try await finder.find()
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.photos.map { $0.item.url.lastPathComponent }, ["IMG_1.pgm", "IMG_1 small.pgm"])
        XCTAssertEqual(group.best.pixelWidth, 160)
        XCTAssertEqual(group.reclaimableBytes, group.photos[1].item.size)
        XCTAssertTrue(group.photos.allSatisfy { !$0.item.isSelected }, "nothing is preselected")
        XCTAssertTrue(group.photos.allSatisfy { finder.safePaths.permits($0.item.url) })
    }

    func testSelectionAlwaysKeepsOnePhoto() async throws {
        try write("a.pgm", photo(width: 160, height: 120, seed: 3))
        try write("b.pgm", photo(width: 120, height: 90, seed: 3, noise: 3))
        try write("c.pgm", photo(width: 100, height: 75, seed: 3, brightness: 8))
        let groups = try await SimilarPhotoFinder(roots: [root], minimumSize: 1000, extensions: ["pgm"], decode: decodePGM).find()
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.photos.count, 3)

        let selected = SimilarPhotoFinder.selectAllButBest(groups)
        XCTAssertEqual(selected, Set(group.photos.dropFirst().map(\.id)))
        XCTAssertFalse(selected.contains(group.best.id))
        XCTAssertTrue(SimilarPhotoFinder.groupsLosingEveryPhoto(groups, selected: selected).isEmpty)
        XCTAssertEqual(SimilarPhotoFinder.groupsLosingEveryPhoto(groups, selected: Set(group.photos.map(\.id))).count, 1)
    }
}
