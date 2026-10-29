import Foundation

/// Package-manager caches in the home folder (Homebrew, npm, pip and the like). Tools download again
/// whatever they need from these, so they're safe to clean; part of System Junk.
public struct PackageCacheScanner: CleaningScanner {
    public struct Cache: Sendable {
        public let category: String
        public let relativePath: String
    }

    public static let caches: [Cache] = [
        Cache(category: "Homebrew cache", relativePath: "Library/Caches/Homebrew"),
        Cache(category: "npm cache", relativePath: ".npm/_cacache"),
        Cache(category: "Yarn cache", relativePath: "Library/Caches/Yarn"),
        Cache(category: "pnpm store", relativePath: "Library/pnpm/store"),
        Cache(category: "pip cache", relativePath: "Library/Caches/pip"),
        Cache(category: "Cargo cache", relativePath: ".cargo/registry/cache"),
        Cache(category: "Gradle cache", relativePath: ".gradle/caches"),
        Cache(category: "Go download cache", relativePath: "go/pkg/mod/cache/download"),
        Cache(category: "CocoaPods cache", relativePath: "Library/Caches/CocoaPods"),
        Cache(category: "Conda packages", relativePath: ".conda/pkgs"),
    ]

    public let name = "Package caches"
    public let home: URL
    /// The time caches in use are measured from.
    public let now: Date

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()) {
        self.home = home
        self.now = now
    }

    public var safePaths: SafePaths {
        SafePaths(allowedRoots: Self.caches.map { home.appendingPathComponent($0.relativePath) })
    }

    public func scan(progress: @Sendable (ScanProgress) -> Void) async throws -> [ScanItem] {
        var items: [ScanItem] = []
        for cache in Self.caches {
            try Task.checkCancellation()
            let url = home.appendingPathComponent(cache.relativePath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            progress(ScanProgress(completed: items.count, total: nil, currentPath: url.path))
            let usage = DiskUsage.usage(of: url)
            if usage.size > 0 {
                // A cache a tool used lately starts unselected, so its next install isn't slowed down by
                // downloading everything again.
                items.append(ScanItem(url: url, size: usage.size, category: cache.category,
                                      isSelected: !CacheUse.isInUse(lastModified: usage.lastModified, now: now),
                                      lastModified: usage.lastModified))
            }
        }
        return items.sorted { $0.size > $1.size }
    }
}
