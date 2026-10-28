import Foundation

/// An 8-bit grayscale image, stored row by row from the top.
public struct GrayImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init?(width: Int, height: Int, pixels: [UInt8]) {
        guard width > 0, height > 0, pixels.count == width * height else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public subscript(x: Int, y: Int) -> UInt8 { pixels[y * width + x] }

    /// Brightest minus darkest pixel.
    public var contrast: Int { Int(pixels.max()!) - Int(pixels.min()!) }

    /// A copy at another size; each new pixel is the average of the pixels it covers.
    public func resized(width newWidth: Int, height newHeight: Int) -> GrayImage {
        precondition(newWidth > 0 && newHeight > 0)
        var result: [UInt8] = []
        result.reserveCapacity(newWidth * newHeight)
        for y in 0..<newHeight {
            let y0 = y * height / newHeight
            let y1 = max(y0 + 1, (y + 1) * height / newHeight)
            for x in 0..<newWidth {
                let x0 = x * width / newWidth
                let x1 = max(x0 + 1, (x + 1) * width / newWidth)
                var sum = 0
                for sy in y0..<y1 {
                    for sx in x0..<x1 { sum += Int(pixels[sy * width + sx]) }
                }
                let count = (y1 - y0) * (x1 - x0)
                result.append(UInt8((sum + count / 2) / count))
            }
        }
        return GrayImage(width: newWidth, height: newHeight, pixels: result)!
    }
}

/// Difference hashes of a small grayscale preview. Resized, recompressed or lightly edited copies of
/// a photo get hashes a few bits apart; unrelated photos differ in about half of the 64 bits.
public struct PerceptualHash: Hashable, Sendable {
    /// Bit set where a pixel is brighter than its right neighbour, on a 9 × 8 preview.
    public let horizontal: UInt64
    /// Bit set where a pixel is brighter than the one below it, on an 8 × 9 preview.
    public let vertical: UInt64

    public init(horizontal: UInt64, vertical: UInt64) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    /// Nil for images with almost no detail (blank or one colour), which would all look alike.
    public init?(_ image: GrayImage, minimumContrast: Int = 10) {
        let wide = image.resized(width: 9, height: 8)
        let tall = image.resized(width: 8, height: 9)
        guard wide.contrast >= minimumContrast else { return nil }
        var horizontal: UInt64 = 0
        var vertical: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                let bit = UInt64(1) << UInt64(y * 8 + x)
                if wide[x, y] > wide[x + 1, y] { horizontal |= bit }
                if tall[x, y] > tall[x, y + 1] { vertical |= bit }
            }
        }
        self.init(horizontal: horizontal, vertical: vertical)
    }

    /// How many bits differ, taking the worse of the two hashes (0 to 64).
    public func distance(to other: PerceptualHash) -> Int {
        max((horizontal ^ other.horizontal).nonzeroBitCount, (vertical ^ other.vertical).nonzeroBitCount)
    }
}

/// What a decoder reads from an image file: a small preview and the full size in pixels.
public struct DecodedPhoto: Sendable {
    public let preview: GrayImage
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(preview: GrayImage, pixelWidth: Int, pixelHeight: Int) {
        self.preview = preview
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public struct SimilarPhoto: Identifiable, Sendable {
    public let item: ScanItem
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let hash: PerceptualHash

    public var id: UUID { item.id }
    public var pixelCount: Int { pixelWidth * pixelHeight }
}

/// Photos that look alike, best first (most pixels, then largest file, then oldest).
/// Nothing is preselected, and at least one photo of each group must be kept.
public struct SimilarPhotoGroup: Identifiable, Sendable {
    public let photos: [SimilarPhoto]

    public var id: UUID { photos[0].id }
    public var best: SimilarPhoto { photos[0] }
    /// Space freed by keeping only the best photo.
    public var reclaimableBytes: Int64 { photos.dropFirst().reduce(0) { $0 + $1.item.size } }
}

/// Finds photos that look alike (bursts, edited or resized copies) in folders the user picks.
/// It reads only what the decoder needs for a small preview; nothing is changed.
public struct SimilarPhotoFinder: Sendable {
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "webp", "bmp",
        "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2",
    ]

    public let roots: [URL]
    public let minimumSize: Int64
    /// How many hash bits may differ for two photos to count as similar.
    public let maxDistance: Int
    public let extensions: Set<String>
    public let skipping: SkippedFolders
    let decode: @Sendable (URL) -> DecodedPhoto?

    public init(roots: [URL], minimumSize: Int64 = 50_000, maxDistance: Int = 8, extensions: Set<String> = imageExtensions,
                skipping: SkippedFolders = .standard, decode: @escaping @Sendable (URL) -> DecodedPhoto?) {
        self.roots = roots
        self.minimumSize = max(1, minimumSize)
        self.maxDistance = maxDistance
        self.extensions = extensions
        self.skipping = skipping
        self.decode = decode
    }

    #if canImport(ImageIO)
    /// Decodes photos with ImageIO.
    public init(roots: [URL], minimumSize: Int64 = 50_000, maxDistance: Int = 8, skipping: SkippedFolders = .standard) {
        self.init(roots: roots, minimumSize: minimumSize, maxDistance: maxDistance, skipping: skipping, decode: DecodedPhoto.imageIO)
    }
    #endif

    /// The folders the user chose; only files inside them can be cleaned.
    public var safePaths: SafePaths { SafePaths(allowedRoots: roots) }

    public func find(progress: @Sendable (ScanProgress) -> Void = { _ in }) async throws -> [SimilarPhotoGroup] {
        // Cloud placeholders (no data on disk) are skipped: decoding them would download them.
        let files = DuplicateFinder.droppingHardLinks(
            try FileWalker.files(under: roots, minimumSize: minimumSize, skipping: skipping, progress: progress)
                .filter { $0.allocatedSize > 0 && extensions.contains($0.url.pathExtension.lowercased()) })
        let photos = try await hashAll(files, progress: progress)
        return try Self.clusters(photos.map(\.hash), maxDistance: maxDistance)
            .map { members in SimilarPhotoGroup(photos: members.map { photos[$0] }.sorted(by: Self.isBetter)) }
            .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    /// Selects every photo except the best in each group.
    public static func selectAllButBest(_ groups: [SimilarPhotoGroup]) -> Set<UUID> {
        Set(groups.flatMap { $0.photos.dropFirst().map(\.id) })
    }

    /// Groups where the selection would remove every photo. Cleaning must be refused while any exist.
    public static func groupsLosingEveryPhoto(_ groups: [SimilarPhotoGroup], selected: Set<UUID>) -> [SimilarPhotoGroup] {
        groups.filter { group in group.photos.allSatisfy { selected.contains($0.id) } }
    }

    // MARK: - Steps

    /// Decodes and hashes a few files at a time. Unreadable and featureless images drop out.
    private func hashAll(_ files: [FileInfo], progress: @Sendable (ScanProgress) -> Void) async throws -> [SimilarPhoto] {
        let decode = self.decode
        let hashFile: @Sendable (FileInfo) -> (URL, SimilarPhoto?) = { file in
            guard let decoded = decode(file.url), let hash = PerceptualHash(decoded.preview) else { return (file.url, nil) }
            let item = ScanItem(url: file.url, size: file.allocatedSize, category: "Similar photos", lastModified: file.modified)
            return (file.url, SimilarPhoto(item: item, pixelWidth: decoded.pixelWidth, pixelHeight: decoded.pixelHeight, hash: hash))
        }
        let photos = try await withThrowingTaskGroup(of: (URL, SimilarPhoto?).self) { group -> [SimilarPhoto] in
            var pending = files.makeIterator()
            for _ in 0..<max(2, ProcessInfo.processInfo.activeProcessorCount) {
                guard let file = pending.next() else { break }
                group.addTask { hashFile(file) }
            }
            var photos: [SimilarPhoto] = []
            var done = 0
            while let (url, photo) = try await group.next() {
                try Task.checkCancellation()
                done += 1
                progress(ScanProgress(completed: done, total: files.count, currentPath: url.path))
                if let photo { photos.append(photo) }
                if let file = pending.next() { group.addTask { hashFile(file) } }
            }
            return photos
        }
        return photos.sorted { $0.item.url.path < $1.item.url.path }
    }

    /// Groups of indices whose hashes are within `maxDistance` of each other, joined transitively.
    /// Photos with no similar partner are left out.
    static func clusters(_ hashes: [PerceptualHash], maxDistance: Int) throws -> [[Int]] {
        var parent = Array(hashes.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        for i in hashes.indices {
            if i % 256 == 0 { try Task.checkCancellation() }
            for j in (i + 1)..<hashes.count where hashes[i].distance(to: hashes[j]) <= maxDistance {
                let (a, b) = (root(i), root(j))
                if a != b { parent[b] = a }
            }
        }
        return Dictionary(grouping: hashes.indices, by: { root($0) }).values
            .filter { $0.count > 1 }
            .map { $0.sorted() }
            .sorted { $0[0] < $1[0] }
    }

    /// Most pixels first, then the largest file, then the oldest.
    static func isBetter(_ a: SimilarPhoto, _ b: SimilarPhoto) -> Bool {
        if a.pixelCount != b.pixelCount { return a.pixelCount > b.pixelCount }
        if a.item.size != b.item.size { return a.item.size > b.item.size }
        let (dateA, dateB) = (a.item.lastModified ?? .distantFuture, b.item.lastModified ?? .distantFuture)
        if dateA != dateB { return dateA < dateB }
        return a.item.url.path < b.item.url.path
    }
}
