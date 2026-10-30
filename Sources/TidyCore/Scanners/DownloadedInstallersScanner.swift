import Foundation

/// Disk images and installer packages left in Downloads once they've done their job. Those downloaded
/// more than a week ago are selected: what they installed is in place by then, and their developers
/// let you download them again. Newer ones may not be opened yet, so they're only listed.
public struct DownloadedInstallersScanner: CleaningScanner {
    public static let category = "Installers in Downloads"
    static let extensions: Set<String> = ["dmg", "pkg", "mpkg", "xip"]
    static let unselectedFor: TimeInterval = 7 * 86_400

    public let name = DownloadedInstallersScanner.category
    public let folder: URL
    /// The time a download's age is measured from.
    public let now: Date

    public init(folder: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"), now: Date = Date()) {
        self.folder = folder
        self.now = now
    }

    /// Only the installers themselves, not the rest of Downloads.
    public var safePaths: SafePaths {
        SafePaths(allowedRoots: installers())
    }

    public func scan(progress: @Sendable (ScanProgress) -> Void) async throws -> [ScanItem] {
        let found = installers()
        var items: [ScanItem] = []
        for (index, url) in found.enumerated() {
            try Task.checkCancellation()
            progress(ScanProgress(completed: index, total: found.count, currentPath: url.path))
            let usage = DiskUsage.usage(of: url)
            let old = usage.lastModified.map { now.timeIntervalSince($0) > Self.unselectedFor } ?? false
            items.append(ScanItem(url: url, size: usage.size, category: Self.category, isSelected: old, lastModified: usage.lastModified))
        }
        progress(ScanProgress(completed: found.count, total: found.count, currentPath: nil))
        return items.sorted { $0.size > $1.size }
    }

    /// The installers directly in the folder.
    func installers() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { Self.extensions.contains($0.pathExtension.lowercased()) }
    }
}
