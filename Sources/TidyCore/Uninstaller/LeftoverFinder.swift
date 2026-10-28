import Foundation

/// Finds files apps leave in ~/Library, by bundle id (and, more cautiously, by app name).
public struct LeftoverFinder: Sendable {
    struct Location: Sendable {
        let category: String
        let folder: String
        /// Whether an entry named after the app (not its bundle id) counts here.
        let matchesAppName: Bool
        /// Whether entries here can be judged orphaned by bundle id alone.
        let orphanCandidate: Bool
        /// Entries are reports named after the app and a date ("Spotify-2026-10-28-101500.ips").
        var reports = false
    }

    static let locations: [Location] = [
        Location(category: "Application Support", folder: "Application Support", matchesAppName: true, orphanCandidate: true),
        Location(category: "Caches", folder: "Caches", matchesAppName: true, orphanCandidate: true),
        Location(category: "Preferences", folder: "Preferences", matchesAppName: false, orphanCandidate: true),
        Location(category: "Preferences", folder: "Preferences/ByHost", matchesAppName: false, orphanCandidate: false),
        Location(category: "Containers", folder: "Containers", matchesAppName: false, orphanCandidate: true),
        Location(category: "Group Containers", folder: "Group Containers", matchesAppName: false, orphanCandidate: false),
        Location(category: "Saved state", folder: "Saved Application State", matchesAppName: false, orphanCandidate: true),
        Location(category: "Web data", folder: "HTTPStorages", matchesAppName: false, orphanCandidate: true),
        Location(category: "Web data", folder: "WebKit", matchesAppName: false, orphanCandidate: true),
        Location(category: "Cookies", folder: "Cookies", matchesAppName: false, orphanCandidate: true),
        Location(category: "Logs", folder: "Logs", matchesAppName: true, orphanCandidate: false),
        Location(category: "Launch agents", folder: "LaunchAgents", matchesAppName: false, orphanCandidate: true),
        Location(category: "Application Scripts", folder: "Application Scripts", matchesAppName: false, orphanCandidate: true),
        Location(category: "Recent documents list",
                 folder: "Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments",
                 matchesAppName: false, orphanCandidate: true),
        Location(category: "Crash reports", folder: "Logs/DiagnosticReports", matchesAppName: false, orphanCandidate: false, reports: true),
        // These two exist only in /Library.
        Location(category: "Launch daemons", folder: "LaunchDaemons", matchesAppName: false, orphanCandidate: false),
        Location(category: "Helper tools", folder: "PrivilegedHelperTools", matchesAppName: false, orphanCandidate: false),
    ]

    public let library: URL

    public init(library: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")) {
        self.library = library
    }

    /// The Library folder shared by all users; what's there usually needs the admin helper to remove.
    public static let system = LeftoverFinder(library: URL(fileURLWithPath: "/Library"))

    /// Every folder this finder looks in; the allowlist for removing what it finds.
    public var searchedFolders: [URL] {
        Self.locations.map { library.appendingPathComponent($0.folder) }
    }

    /// Leftovers of one app. `installedBundleIDs` keeps data that belongs to a different installed app
    /// with a longer, more specific id (com.foo.app.pro is not a leftover of com.foo.app). With
    /// `appURL`, launch jobs that run something inside the app, the privileged helpers the app
    /// installs, and the helper tools those jobs run count too, whatever they're named.
    public func leftovers(bundleID: String, appName: String, installedBundleIDs: Set<String>, appURL: URL? = nil) -> [ScanItem] {
        let id = bundleID.lowercased()
        let name = appName.lowercased()
        let installed = Set(installedBundleIDs.map { $0.lowercased() }).union([id])
        let helperLabels = appURL.map(Self.privilegedHelperLabels) ?? []
        var items: [ScanItem] = []
        var found = Set<String>()
        func add(_ entry: URL, _ category: String, selected: Bool) {
            guard found.insert(entry.path).inserted else { return }
            items.append(ScanItem(url: entry, size: DiskUsage.size(of: entry), category: category, isSelected: selected))
        }

        for location in Self.locations {
            for entry in entries(in: location) {
                let base = Self.baseName(entry.lastPathComponent).lowercased()
                let byID: Bool
                if location.folder == "Group Containers" {
                    // Named "<team id>.<bundle id>" or "group.<bundle id>"; a vendor-wide group is left alone.
                    byID = base.hasSuffix("." + id)
                } else {
                    byID = Self.owner(of: base, among: installed) == id
                }
                let byName = location.reports ? Self.isReport(entry.lastPathComponent.lowercased(), of: name)
                                              : location.matchesAppName && base == name
                let byHelper = Self.helperFolders.contains(location.folder) && helperLabels.contains(base)
                let byProgram = appURL.map { Self.isLaunchJob(entry, in: location, runningInside: $0) } ?? false
                guard byID || byName || byHelper || byProgram else { continue }
                // A match by name alone is left for you to check when the name is too short to tell.
                add(entry, location.category, selected: byID || byHelper || byProgram || name.count >= 3)
            }
        }
        // The helper tools this app's launch jobs run.
        let tools = library.appendingPathComponent("PrivilegedHelperTools").path
        for item in items where item.category == "Launch daemons" || item.category == "Launch agents" {
            guard let program = Self.program(of: item.url), URL(fileURLWithPath: program).deletingLastPathComponent().path == tools,
                  FileManager.default.fileExists(atPath: program) else { continue }
            add(URL(fileURLWithPath: program), "Helper tools", selected: true)
        }
        return items
    }

    /// Data in bundle-id-named folders whose app isn't installed. Never preselected: apps installed
    /// outside the scanned folders, or helper tools, can look the same.
    public func orphans(installedBundleIDs: Set<String>) -> [ScanItem] {
        let installed = Set(installedBundleIDs.map { $0.lowercased() })
        var items: [ScanItem] = []
        for location in Self.locations where location.orphanCandidate {
            for entry in entries(in: location) {
                let base = Self.baseName(entry.lastPathComponent).lowercased()
                guard Self.looksLikeBundleID(base),
                      !base.hasPrefix("com.apple."),
                      Self.owner(of: base, among: installed) == nil,
                      // A vendor folder such as com.foo still belongs to an installed com.foo.app.
                      !installed.contains(where: { $0.hasPrefix(base + ".") })
                else { continue }
                items.append(ScanItem(url: entry, size: DiskUsage.size(of: entry), category: "Leftovers: \(location.category)", isSelected: false))
            }
        }
        return items
    }

    // MARK: - Matching

    private func entries(in location: Location) -> [URL] {
        let folder = library.appendingPathComponent(location.folder)
        return (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    /// The most specific installed bundle id that `base` is named after (equal, or id + "." + suffix).
    static func owner(of base: String, among installed: Set<String>) -> String? {
        installed
            .filter { base == $0 || base.hasPrefix($0 + ".") }
            .max { $0.count < $1.count }
    }

    static func baseName(_ name: String) -> String {
        for suffix in [".plist", ".savedState", ".binarycookies", ".sfl", ".sfl2", ".sfl3"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    /// A crash or hang report of the app, such as "spotify-2026-10-28-101500.ips" (lowercased).
    static func isReport(_ file: String, of name: String) -> Bool {
        guard name.count >= 3, file.hasPrefix(name), let next = file.dropFirst(name.count).first, "-_ ".contains(next) else { return false }
        return [".ips", ".crash", ".diag", ".hang", ".spin"].contains { file.hasSuffix($0) }
    }

    // MARK: - Launch jobs and helpers

    /// Where an app's privileged helpers go: the daemon's plist, and the tool it runs.
    static let helperFolders: Set<String> = ["LaunchDaemons", "PrivilegedHelperTools"]

    /// The labels of the privileged helpers an app installs (SMPrivilegedExecutables), lowercased.
    static func privilegedHelperLabels(_ appURL: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let helpers = plist["SMPrivilegedExecutables"] as? [String: Any]
        else { return [] }
        return Set(helpers.keys.map { $0.lowercased() })
    }

    /// A launch job's program, from its plist.
    static func program(of plist: URL) -> String? {
        LaunchItemReader.item(at: plist, scope: .daemon)?.program
    }

    /// Whether a plist in a launch agents or daemons folder runs something inside the app.
    static func isLaunchJob(_ entry: URL, in location: Location, runningInside appURL: URL) -> Bool {
        guard location.folder == "LaunchAgents" || location.folder == "LaunchDaemons",
              let program = program(of: entry) else { return false }
        return program.hasPrefix(appURL.path + "/")
    }

    /// Reverse-DNS with at least three parts, e.g. com.example.app.
    static func looksLikeBundleID(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }
}
