import Foundation

public struct InstalledApp: Identifiable, Hashable, Sendable {
    public let url: URL
    public let bundleID: String
    public let name: String
    public let version: String?
    /// CFBundleVersion, which Sparkle compares against.
    public let buildVersion: String?
    /// Sparkle's update feed, for apps that update themselves with Sparkle.
    public let sparkleFeedURL: URL?
    public let isFromAppStore: Bool

    public var id: String { url.path }

    /// Reads an .app bundle's Info.plist. Returns nil for anything that isn't an app with a bundle id.
    /// iPhone and iPad apps installed on a Mac keep theirs inside Wrapper/<name>.app.
    public init?(bundleURL: URL) {
        guard bundleURL.pathExtension == "app",
              let data = (try? Data(contentsOf: bundleURL.appendingPathComponent("Contents/Info.plist")))
                ?? Self.wrappedInfoPlist(in: bundleURL),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty
        else { return nil }
        self.url = bundleURL
        self.bundleID = bundleID
        self.name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        self.version = plist["CFBundleShortVersionString"] as? String
        self.buildVersion = plist["CFBundleVersion"] as? String
        self.sparkleFeedURL = (plist["SUFeedURL"] as? String).flatMap(URL.init(string:))
        self.isFromAppStore = FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("Contents/_MASReceipt/receipt").path)
            || FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("Wrapper/iTunesMetadata.plist").path)
    }

    private static func wrappedInfoPlist(in bundleURL: URL) -> Data? {
        let wrapper = bundleURL.appendingPathComponent("Wrapper")
        guard let inner = (try? FileManager.default.contentsOfDirectory(at: wrapper, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" })
        else { return nil }
        return try? Data(contentsOf: inner.appendingPathComponent("Info.plist"))
    }
}

public enum AppInventory {
    public static func defaultFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
    }

    /// Folders whose apps can't be uninstalled but whose bundle ids still count as installed.
    public static let systemFolders = [URL(fileURLWithPath: "/System/Applications")]

    /// The folders `apps(in:)` reads: the folders themselves and the folders one level down.
    public static func foldersHoldingApps(_ folders: [URL]) -> [URL] {
        let fm = FileManager.default
        return folders.filter { fm.fileExists(atPath: $0.path) } + folders.flatMap { folder in
            ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.pathExtension != "app" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
    }

    /// Apps directly inside the folders, plus one level down (Utilities, vendor folders).
    public static func apps(in folders: [URL]) -> [InstalledApp] {
        let fm = FileManager.default
        var apps: [InstalledApp] = []
        for folder in folders {
            guard let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for child in children {
                if child.pathExtension == "app" {
                    if let app = InstalledApp(bundleURL: child) { apps.append(app) }
                } else if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          let nested = try? fm.contentsOfDirectory(at: child, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    apps += nested.filter { $0.pathExtension == "app" }.compactMap(InstalledApp.init(bundleURL:))
                }
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Every app on the Mac: the app folders' and, wherever else they are, the ones Spotlight knows.
    public static func everyApp(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [InstalledApp] {
        let listed = apps(in: defaultFolders(home: home) + systemFolders)
        let seen = Set(listed.map(\.url.path))
        return listed + spotlightApps().filter { !seen.contains($0.url.path) }
    }

    /// The apps Spotlight has found outside /System; none when Spotlight is off or can't answer.
    static func spotlightApps() -> [InstalledApp] {
        #if os(macOS)
        guard let result = try? Subprocess.run(URL(fileURLWithPath: "/usr/bin/mdfind"),
                                               ["kMDItemContentType == 'com.apple.application-bundle'"]),
              result.status == 0 else { return [] }
        return result.output.split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("/System/") && !$0.contains("/.Trash/") }
            .compactMap { InstalledApp(bundleURL: URL(fileURLWithPath: $0)) }
        #else
        return []
        #endif
    }
}
