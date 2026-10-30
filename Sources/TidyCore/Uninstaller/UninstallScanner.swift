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

/// What apps you removed left behind, in your Library and in /Library (see `LeftoverFinder.orphans`), for
/// System Junk. From /Library, only what the admin helper would accept is offered.
public struct OrphanedLeftoversScanner: CleaningScanner {
    public let name = LeftoverFinder.orphanCategory
    public let finder: LeftoverFinder
    /// Usually `LeftoverFinder.system`.
    public let systemFinder: LeftoverFinder?
    /// The apps on the Mac, read when the scan starts.
    public let apps: @Sendable () -> [InstalledApp]
    /// What the admin helper accepts from `systemFinder`'s folders.
    public let policy: HelperPolicy

    public init(finder: LeftoverFinder = LeftoverFinder(), systemFinder: LeftoverFinder? = .system,
                apps: @escaping @Sendable () -> [InstalledApp] = { AppInventory.everyApp() }, policy: HelperPolicy = .standard) {
        self.finder = finder
        self.systemFinder = systemFinder
        self.apps = apps
        self.policy = policy
    }

    private var finders: [LeftoverFinder] { [finder] + (systemFinder.map { [$0] } ?? []) }

    public var safePaths: SafePaths {
        SafePaths(allowedRoots: finders.flatMap(\.searchedFolders))
    }

    public func scan(progress: @Sendable (ScanProgress) -> Void) async throws -> [ScanItem] {
        progress(ScanProgress(completed: 0, total: 2, currentPath: finder.library.path))
        let known = KnownApps(apps(), libraries: finders.map(\.library))
        let support = finders.flatMap { [$0.library.appendingPathComponent("Application Support").path,
                                         $0.library.appendingPathComponent("PrivilegedHelperTools").path] }
        var items = finder.orphans(known: known, supportFolders: support)
        if let systemFinder {
            try Task.checkCancellation()
            progress(ScanProgress(completed: 1, total: 2, currentPath: systemFinder.library.path))
            items += systemFinder.orphans(known: known, supportFolders: support).filter { policy.accepts($0.url) }
        }
        // Once some of a vendor's leftovers show all its apps are gone, folders named after it count too.
        let gone = Set(items.compactMap { item -> String? in
            let base = LeftoverFinder.baseName(item.url.lastPathComponent).lowercased()
            guard LeftoverFinder.looksLikeBundleID(base), !known.hasVendor(of: base) else { return nil }
            return KnownApps.vendor(of: base)
        })
        items += finder.vendorFolders(gone)
        items += systemFinder?.vendorFolders(gone).filter { policy.accepts($0.url) } ?? []
        progress(ScanProgress(completed: 2, total: 2, currentPath: nil))
        return items.sorted { $0.size > $1.size }
    }
}
