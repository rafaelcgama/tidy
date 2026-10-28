import Foundation

/// Apple's "Install macOS …" apps, 12 GB or more each. One for the macOS this Mac already runs, or an
/// older one, is preselected: it isn't needed to upgrade, and Apple lets you download it again. One for
/// a newer macOS may be about to be used, so it's listed but not preselected.
public struct MacInstallerScanner: CleaningScanner {
    public static let defaultFolders = [URL(fileURLWithPath: "/Applications")]

    /// The version each installer installs, by the name it's called after. Newer ones, missing here, are never preselected.
    static let releases: [(name: String, version: [Int])] = [
        ("Tahoe", [26]), ("Sequoia", [15]), ("Sonoma", [14]), ("Ventura", [13]), ("Monterey", [12]), ("Big Sur", [11]),
        ("Catalina", [10, 15]), ("Mojave", [10, 14]), ("High Sierra", [10, 13]), ("Sierra", [10, 12]), ("El Capitan", [10, 11]),
        ("Yosemite", [10, 10]),
    ]

    public let name = "macOS installers"
    public let folders: [URL]
    /// The macOS this Mac runs, as major and minor version.
    public let runningVersion: [Int]

    public init(folders: [URL] = MacInstallerScanner.defaultFolders,
                runningVersion: [Int] = [ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                                         ProcessInfo.processInfo.operatingSystemVersion.minorVersion]) {
        self.folders = folders
        self.runningVersion = runningVersion
    }

    /// Only the installers themselves, not the rest of the Applications folder.
    public var safePaths: SafePaths {
        SafePaths(allowedRoots: installers().map(\.url))
    }

    public func scan(progress: @Sendable (ScanProgress) -> Void) async throws -> [ScanItem] {
        let found = installers()
        var items: [ScanItem] = []
        for (index, installer) in found.enumerated() {
            try Task.checkCancellation()
            progress(ScanProgress(completed: index, total: found.count, currentPath: installer.url.path))
            let usage = DiskUsage.usage(of: installer.url)
            let version = Self.version(ofInstallerNamed: installer.name)
                ?? Self.version(ofInstallerNamed: installer.url.deletingPathExtension().lastPathComponent)
            // Not newer than what runs here.
            let old = version.map { !runningVersion.lexicographicallyPrecedes($0) } ?? false
            items.append(ScanItem(url: installer.url, size: usage.size, category: "macOS installers", isSelected: old,
                                  lastModified: usage.lastModified))
        }
        progress(ScanProgress(completed: found.count, total: found.count, currentPath: nil))
        return items.sorted { $0.size > $1.size }
    }

    /// Apps in the folders named "Install …" whose bundle id says they're Apple's macOS installers.
    func installers() -> [InstalledApp] {
        folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.pathExtension == "app" && $0.lastPathComponent.hasPrefix("Install ") }
                .compactMap(InstalledApp.init(bundleURL:))
                .filter { $0.bundleID.hasPrefix("com.apple.InstallAssistant.") }
        }
    }

    /// [14] for "Install macOS Sonoma", [10, 13] for "Install macOS High Sierra"; nil for a name not known here.
    static func version(ofInstallerNamed name: String) -> [Int]? {
        var rest = Substring(name)
        for prefix in ["Install macOS ", "Install OS X "] where rest.hasPrefix(prefix) {
            rest = rest.dropFirst(prefix.count)
        }
        return releases.first { rest.hasPrefix($0.name) }?.version
    }
}
