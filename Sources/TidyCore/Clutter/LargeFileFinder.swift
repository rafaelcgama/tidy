import Foundation

/// Big files in the folders the user picks, grouped by size and by how long since they changed.
/// These are the user's own files, so nothing is preselected.
public struct LargeFileFinder: CleaningScanner {
    public let name = "Large & old files"
    public let roots: [URL]
    public let minimumSize: Int64
    public let oldAfter: TimeInterval
    public let now: Date
    public let skipping: SkippedFolders

    public init(roots: [URL], minimumSize: Int64 = 100_000_000, oldAfter: TimeInterval = 365 * 86_400, now: Date = Date(),
                skipping: SkippedFolders = .standard) {
        self.roots = roots
        self.minimumSize = minimumSize
        self.oldAfter = oldAfter
        self.now = now
        self.skipping = skipping
    }

    public var safePaths: SafePaths { SafePaths(allowedRoots: roots) }

    public func scan(progress: @Sendable (ScanProgress) -> Void) async throws -> [ScanItem] {
        let files = try FileWalker.files(under: roots, minimumSize: minimumSize, skipping: skipping, progress: progress)
        return files
            .map { ScanItem(url: $0.url, size: $0.allocatedSize, category: category(for: $0), lastModified: $0.modified) }
            .sorted { $0.size > $1.size }
    }

    private func category(for file: FileInfo) -> String {
        if let modified = file.modified, now.timeIntervalSince(modified) > oldAfter {
            return "Not changed in over \(Int(oldAfter / 86_400)) days"
        }
        return file.size >= 1_000_000_000 ? "Over 1 GB" : "Over \(ByteFormat.string(minimumSize))"
    }
}
