import Foundation

/// Package-manager caches in the home folder, plus build output inside project folders
/// (node_modules, Rust target, SwiftPM .build). Everything here can be re-downloaded or rebuilt.
public struct DeveloperJunkScanner: CleaningScanner {
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

    /// Build-output folder name and the file that must sit next to it to prove it's a project.
    static let buildFolders: [(folder: String, marker: String, category: String)] = [
        ("node_modules", "package.json", "node_modules"),
        ("target", "Cargo.toml", "Rust build output"),
        (".build", "Package.swift", "Swift build output"),
    ]

    public let name = "Developer junk"
    public let home: URL
    public let projectRoots: [URL]
    /// The time caches in use are measured from.
    public let now: Date

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, projectRoots: [URL], now: Date = Date()) {
        self.home = home
        self.projectRoots = projectRoots
        self.now = now
    }

    public var safePaths: SafePaths {
        SafePaths(allowedRoots: Self.caches.map { home.appendingPathComponent($0.relativePath) } + projectRoots)
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
                // Pure caches: tools download again what they need. One a tool used lately starts unselected,
                // so its next install isn't slowed down by downloading everything again.
                items.append(ScanItem(url: url, size: usage.size, category: cache.category,
                                      isSelected: !CacheUse.isInUse(lastModified: usage.lastModified, now: now),
                                      lastModified: usage.lastModified))
            }
        }
        for root in projectRoots {
            items += try buildOutput(under: root, progress: progress)
        }
        return items.sorted { $0.size > $1.size }
    }

    /// Projects may be in use, so build output is listed but not preselected.
    private func buildOutput(under root: URL, progress: (ScanProgress) -> Void) throws -> [ScanItem] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                                             options: [.skipsPackageDescendants], errorHandler: { _, _ in true })
        else { return [] }

        var items: [ScanItem] = []
        var visited = 0
        for case let url as URL in enumerator {
            if Task.isCancelled { throw CancellationError() }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  values.isDirectory == true, values.isSymbolicLink != true
            else { continue }
            visited += 1
            if visited % 500 == 0 {
                progress(ScanProgress(completed: visited, total: nil, currentPath: url.path))
            }
            let name = url.lastPathComponent
            if let match = Self.buildFolders.first(where: { $0.folder == name }) {
                if fm.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent(match.marker).path) {
                    items.append(ScanItem(url: url, size: DiskUsage.size(of: url), category: match.category,
                                          lastModified: values.contentModificationDate))
                    enumerator.skipDescendants()
                    continue
                }
            }
            // Don't wander into hidden folders (.git and the like) or into dependencies.
            if name.hasPrefix(".") || name == "node_modules" {
                enumerator.skipDescendants()
            }
        }
        return items
    }
}
