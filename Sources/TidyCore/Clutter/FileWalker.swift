import Foundation

struct FileInfo: Sendable {
    let url: URL
    /// Logical size, used to match duplicates.
    let size: Int64
    /// Space on disk, used for what cleaning frees.
    let allocatedSize: Int64
    let modified: Date?
}

enum FileWalker {
    private static let keys: [URLResourceKey] = [
        .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey,
        .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey,
    ]

    /// Regular files of at least `minimumSize` bytes under the roots. Skips hidden files, package
    /// contents (apps, the Photos library), symlinks, anything SafePaths forbids, and the app data and
    /// project dependencies that `skipping` leaves out.
    static func files(under roots: [URL], minimumSize: Int64, forbidden: [URL] = SafePaths.defaultForbidden,
                      skipping: SkippedFolders = .standard, progress: (ScanProgress) -> Void) throws -> [FileInfo] {
        let safePaths = SafePaths(allowedRoots: roots, forbiddenRoots: forbidden)
        var files: [FileInfo] = []
        var visited = 0
        for root in roots {
            let search = skipping.search(of: root)
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                                  errorHandler: { _, _ in true })
            else { continue }
            for case let url as URL in enumerator {
                if Task.isCancelled { throw CancellationError() }
                visited += 1
                if visited % 1000 == 0 {
                    progress(ScanProgress(completed: visited, total: nil, currentPath: url.path))
                }
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
                if values.isDirectory == true {
                    if !safePaths.permits(url) || search.skips(url, isDirectory: true) { enumerator.skipDescendants() }
                    continue
                }
                guard values.isRegularFile == true else { continue }
                let size = Int64(values.fileSize ?? 0)
                guard size >= minimumSize, size > 0, !search.skips(url, isDirectory: false) else { continue }
                files.append(FileInfo(url: url, size: size,
                                      allocatedSize: Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0),
                                      modified: values.contentModificationDate))
            }
        }
        return files
    }
}
