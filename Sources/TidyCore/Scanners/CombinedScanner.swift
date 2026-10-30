import Foundation

/// Several scanners shown as one, such as System Junk. Overlapping items are listed once.
public struct CombinedScanner: CleaningScanner {
    public let name: String
    public let scanners: [any CleaningScanner]

    public init(name: String, scanners: [any CleaningScanner]) {
        self.name = name
        self.scanners = scanners
    }

    /// What System Junk looks for: package caches, the junk folders, Xcode simulators, macOS installers,
    /// what removed apps left behind and installers in Downloads. Package caches come first, so a cache in
    /// ~/Library/Caches shows under its tool's name, and a removed app's cache shows with the other caches.
    /// `systemLibrary` is where removed apps' helpers and startup items for all users are looked for.
    public static func systemJunk(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                  systemLocations: [SystemJunkScanner.Location] = SystemJunkScanner.systemLocations,
                                  applicationFolders: [URL] = MacInstallerScanner.defaultFolders,
                                  systemLibrary: URL? = LeftoverFinder.system.library) -> CombinedScanner {
        CombinedScanner(name: "System Junk", scanners: [
            PackageCacheScanner(home: home),
            SystemJunkScanner(locations: SystemJunkScanner.defaultLocations(home: home) + systemLocations),
            SimulatorScanner(home: home),
            MacInstallerScanner(folders: applicationFolders),
            OrphanedLeftoversScanner(finder: LeftoverFinder(library: home.appendingPathComponent("Library")),
                                     systemFinder: systemLibrary.map { LeftoverFinder(library: $0, shared: true) },
                                     apps: { AppInventory.everyApp(home: home) }),
            DownloadedInstallersScanner(folder: home.appendingPathComponent("Downloads")),
        ])
    }

    public var safePaths: SafePaths {
        scanners.reduce(SafePaths(allowedRoots: [])) { $0.merging($1.safePaths) }
    }

    public func scan(progress: @Sendable (ScanProgress) -> Void) async throws -> [ScanItem] {
        var items: [ScanItem] = []
        for scanner in scanners {
            try Task.checkCancellation()
            items += try await scanner.scan(progress: progress)
        }
        return SmartCare.withoutOverlaps(items)
    }
}
