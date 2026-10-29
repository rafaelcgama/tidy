import Foundation

/// An app bundle plus everything it left in ~/Library (and, with `systemFinder`, in /Library, and with
/// `packages`, wherever its installer package put files).
public struct UninstallScanner: CleaningScanner {
    public let name = "Uninstaller"
    public let app: InstalledApp
    public let finder: LeftoverFinder
    /// Usually `LeftoverFinder.system`. Only what the admin helper would accept is offered from it.
    public let systemFinder: LeftoverFinder?
    /// Usually `InstallerPackages.system`, for apps installed from a .pkg.
    public let packages: InstallerPackages?
    public let installedBundleIDs: Set<String>

    public init(app: InstalledApp, finder: LeftoverFinder = LeftoverFinder(), systemFinder: LeftoverFinder? = nil,
                packages: InstallerPackages? = nil, installedBundleIDs: Set<String>) {
        self.app = app
        self.finder = finder
        self.systemFinder = systemFinder
        self.packages = packages
        self.installedBundleIDs = installedBundleIDs
    }

    /// Only the app itself and the leftover folders may be touched.
    public var safePaths: SafePaths {
        SafePaths(allowedRoots: [app.url] + finder.searchedFolders + (systemFinder?.searchedFolders ?? [])
                  + (packages?.searchedFolders ?? []))
    }

    public func scan(progress: @Sendable (ScanProgress) -> Void) async throws -> [ScanItem] {
        progress(ScanProgress(completed: 0, total: 2, currentPath: app.url.path))
        let bundle = ScanItem(url: app.url, size: DiskUsage.size(of: app.url), category: "Application", isSelected: true)
        try Task.checkCancellation()
        progress(ScanProgress(completed: 1, total: 2, currentPath: finder.library.path))
        var leftovers = finder.leftovers(bundleID: app.bundleID, appName: app.name, installedBundleIDs: installedBundleIDs, appURL: app.url)
        if let systemFinder {
            leftovers += systemFinder.leftovers(bundleID: app.bundleID, appName: app.name, installedBundleIDs: installedBundleIDs,
                                                appURL: app.url)
                .filter { HelperPolicy.standard.accepts($0.url) }
                .map { ScanItem(url: $0.url, size: $0.size, category: "\($0.category) (all users)", isSelected: $0.isSelected) }
        }
        if let packages {
            try Task.checkCancellation()
            // Compared resolved, so /var and /private/var count as the same place.
            let found = Set(leftovers.map { $0.url.resolvingSymlinksInPath().path })
            leftovers += packages.leftovers(of: app.url).filter { !found.contains($0.url.resolvingSymlinksInPath().path) }
        }
        progress(ScanProgress(completed: 2, total: 2, currentPath: nil))
        return [bundle] + leftovers.sorted { $0.size > $1.size }
    }
}

/// Leftovers of apps that are no longer installed.
public struct OrphanedLeftoversScanner: CleaningScanner {
    public let name = "Leftovers"
    public let finder: LeftoverFinder
    public let installedBundleIDs: Set<String>

    public init(finder: LeftoverFinder = LeftoverFinder(), installedBundleIDs: Set<String>) {
        self.finder = finder
        self.installedBundleIDs = installedBundleIDs
    }

    public var safePaths: SafePaths {
        SafePaths(allowedRoots: finder.searchedFolders)
    }

    public func scan(progress: @Sendable (ScanProgress) -> Void) async throws -> [ScanItem] {
        progress(ScanProgress(completed: 0, total: 1, currentPath: finder.library.path))
        let items = finder.orphans(installedBundleIDs: installedBundleIDs)
        progress(ScanProgress(completed: 1, total: 1, currentPath: nil))
        return items.sorted { $0.size > $1.size }
    }
}
