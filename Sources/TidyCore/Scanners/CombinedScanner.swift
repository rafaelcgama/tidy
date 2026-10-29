import Foundation

/// Several scanners shown as one, such as System Junk. Overlapping items are listed once.
public struct CombinedScanner: CleaningScanner {
    public let name: String
    public let scanners: [any CleaningScanner]

    public init(name: String, scanners: [any CleaningScanner]) {
        self.name = name
        self.scanners = scanners
    }

    /// What System Junk looks for: package caches, the junk folders, Xcode simulators and macOS installers.
    /// Package caches come first, so a cache in ~/Library/Caches shows under its tool's name.
    public static func systemJunk(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                  systemLocations: [SystemJunkScanner.Location] = SystemJunkScanner.systemLocations,
                                  applicationFolders: [URL] = MacInstallerScanner.defaultFolders) -> CombinedScanner {
        CombinedScanner(name: "System Junk", scanners: [
            PackageCacheScanner(home: home),
            SystemJunkScanner(locations: SystemJunkScanner.defaultLocations(home: home) + systemLocations),
            SimulatorScanner(home: home),
            MacInstallerScanner(folders: applicationFolders),
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
