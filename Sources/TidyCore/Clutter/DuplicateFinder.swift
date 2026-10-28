import Foundation

/// Files with identical contents. Nothing is preselected; at least one copy must always be kept.
public struct DuplicateGroup: Identifiable, Sendable {
    public let files: [ScanItem]
    /// Logical size of each copy.
    public let size: Int64

    public var id: UUID { files[0].id }
    /// Space freed by keeping one copy.
    public var wastedBytes: Int64 { files.dropFirst().reduce(0) { $0 + $1.size } }
    /// The copies' file name, when they all have the same one. Copies can have any name.
    public var sharedName: String? {
        let names = Set(files.map { $0.url.lastPathComponent })
        return names.count == 1 ? names.first : nil
    }
}

public struct DuplicateFinder: Sendable {
    public let roots: [URL]
    public let minimumSize: Int64
    /// App data and project dependencies, where identical copies are normal and needed.
    public let skipping: SkippedFolders

    public init(roots: [URL], minimumSize: Int64 = 1_000_000, skipping: SkippedFolders = .standard) {
        self.roots = roots
        self.minimumSize = max(1, minimumSize)
        self.skipping = skipping
    }

    /// The folders the user chose; only files inside them can be cleaned.
    public var safePaths: SafePaths { SafePaths(allowedRoots: roots) }

    /// Size, then a quick hash of the ends, then a full hash, then a byte-by-byte comparison.
    public func find(progress: @Sendable (ScanProgress) -> Void = { _ in }) async throws -> [DuplicateGroup] {
        // Files with no data on disk are cloud placeholders (or fully sparse); reading them would
        // download them, so they are never hashed.
        let files = try FileWalker.files(under: roots, minimumSize: minimumSize, skipping: skipping, progress: progress)
            .filter { $0.allocatedSize > 0 }
        let sizeGroups = Dictionary(grouping: files, by: \.size).values.filter { $0.count > 1 }

        var groups: [DuplicateGroup] = []
        for (index, sameSize) in sizeGroups.enumerated() {
            try Task.checkCancellation()
            progress(ScanProgress(completed: index, total: sizeGroups.count, currentPath: sameSize[0].url.path))
            let candidates = Self.droppingHardLinks(sameSize)
            guard candidates.count > 1 else { continue }

            for quick in try Self.buckets(candidates, by: { try ContentHasher.quickHash(of: $0.url, size: $0.size) }) {
                for full in try Self.buckets(quick, by: { try ContentHasher.fullHash(of: $0.url) }) {
                    for identical in try Self.identicalClasses(full) {
                        let items = identical
                            .sorted { ($0.modified ?? .distantFuture) < ($1.modified ?? .distantFuture) }
                            .map { ScanItem(url: $0.url, size: $0.allocatedSize, category: "Duplicates", lastModified: $0.modified) }
                        groups.append(DuplicateGroup(files: items, size: identical[0].size))
                    }
                }
            }
        }
        return groups.sorted { $0.wastedBytes > $1.wastedBytes }
    }

    /// Selects every copy except the oldest in each group.
    public static func selectAllButOldest(_ groups: [DuplicateGroup]) -> Set<UUID> {
        Set(groups.flatMap { $0.files.dropFirst().map(\.id) })
    }

    /// Groups where the selection would remove every copy. Cleaning must be refused while any exist.
    public static func groupsLosingEveryCopy(_ groups: [DuplicateGroup], selected: Set<UUID>) -> [DuplicateGroup] {
        groups.filter { group in group.files.allSatisfy { selected.contains($0.id) } }
    }

    // MARK: - Steps

    /// Hard links share storage, so removing one frees nothing: keep one path per inode.
    static func droppingHardLinks(_ files: [FileInfo]) -> [FileInfo] {
        var seen = Set<String>()
        return files.filter { file in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.url.path),
                  let inode = attributes[.systemFileNumber], let device = attributes[.systemNumber]
            else { return true }
            return seen.insert("\(device):\(inode)").inserted
        }
    }

    /// Splits files by a key, keeping only buckets with more than one file. Unreadable files drop out.
    static func buckets(_ files: [FileInfo], by key: (FileInfo) throws -> UInt64) throws -> [[FileInfo]] {
        var buckets: [UInt64: [FileInfo]] = [:]
        for file in files {
            try Task.checkCancellation()
            guard let value = try? key(file) else { continue }
            buckets[value, default: []].append(file)
        }
        return buckets.values.filter { $0.count > 1 }
    }

    /// Splits files into classes with byte-identical contents.
    static func identicalClasses(_ files: [FileInfo]) throws -> [[FileInfo]] {
        var classes: [[FileInfo]] = []
        for file in files {
            try Task.checkCancellation()
            if let index = classes.firstIndex(where: { (try? ContentHasher.sameContents($0[0].url, file.url)) == true }) {
                classes[index].append(file)
            } else {
                classes.append([file])
            }
        }
        return classes.filter { $0.count > 1 }
    }
}
