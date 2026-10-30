import Foundation

/// Finds files apps leave in ~/Library, by bundle id (and, more cautiously, by app name).
public struct LeftoverFinder: Sendable {
    /// When an entry here that no app on the Mac owns counts as left over from a removed app (`orphans`).
    enum OrphanRule: Sendable {
        /// Never: names here don't tell whose it is.
        case never
        /// Once no app from its vendor is left, since vendors share what's here (updaters, helpers).
        case vendorGone
        /// Once the app it's named after is gone: only that app makes these. `selected` where removing one
        /// can't hurt even if the app is somewhere Tidy doesn't see (window state, web caches, cookies).
        case appGone(selected: Bool)
        /// Launch jobs, judged by what they start (`orphanedStartupItem`).
        case startupItem
    }

    struct Location: Sendable {
        let category: String
        let folder: String
        /// Whether an entry named after the app (not its bundle id) counts here.
        let matchesAppName: Bool
        let orphans: OrphanRule
        /// Entries are reports named after the app and a date ("Spotify-2026-10-28-101500.ips").
        var reports = false
    }

    static let locations: [Location] = [
        Location(category: "Application Support", folder: "Application Support", matchesAppName: true, orphans: .vendorGone),
        Location(category: "Caches", folder: "Caches", matchesAppName: true, orphans: .vendorGone),
        Location(category: "Preferences", folder: "Preferences", matchesAppName: false, orphans: .vendorGone),
        Location(category: "Preferences", folder: "Preferences/ByHost", matchesAppName: false, orphans: .never),
        // macOS asks before any app reads another app's container, so a scan leaves them alone.
        Location(category: "Containers", folder: "Containers", matchesAppName: false, orphans: .never),
        Location(category: "Group Containers", folder: "Group Containers", matchesAppName: false, orphans: .never),
        Location(category: "Saved state", folder: "Saved Application State", matchesAppName: false, orphans: .appGone(selected: true)),
        Location(category: "Web data", folder: "HTTPStorages", matchesAppName: false, orphans: .appGone(selected: true)),
        Location(category: "Web data", folder: "WebKit", matchesAppName: false, orphans: .appGone(selected: true)),
        Location(category: "Cookies", folder: "Cookies", matchesAppName: false, orphans: .appGone(selected: true)),
        Location(category: "Logs", folder: "Logs", matchesAppName: true, orphans: .never),
        Location(category: "Launch agents", folder: "LaunchAgents", matchesAppName: false, orphans: .startupItem),
        Location(category: "Application Scripts", folder: "Application Scripts", matchesAppName: false, orphans: .appGone(selected: false)),
        Location(category: "Recent documents list",
                 folder: "Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments",
                 matchesAppName: false, orphans: .appGone(selected: true)),
        Location(category: "Crash reports", folder: "Logs/DiagnosticReports", matchesAppName: false, orphans: .never, reports: true),
        // These two exist only in /Library.
        Location(category: "Launch daemons", folder: "LaunchDaemons", matchesAppName: false, orphans: .startupItem),
        Location(category: "Helper tools", folder: "PrivilegedHelperTools", matchesAppName: false, orphans: .vendorGone),
    ]

    public let library: URL
    /// Whether `library` is the one all users share, whose launch agents start at every user's login.
    public let shared: Bool

    public init(library: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library"), shared: Bool = false) {
        self.library = library
        self.shared = shared
    }

    /// The Library folder shared by all users; what's there usually needs the admin helper to remove.
    public static let system = LeftoverFinder(library: URL(fileURLWithPath: "/Library"), shared: true)

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

    public static let orphanCategory = "Leftovers of removed apps"

    /// What removed apps left here, by each folder's `OrphanRule`. Selected only where removing it can't
    /// hurt; the rest is for you to check, since an app kept somewhere Tidy doesn't see looks removed.
    /// `supportFolders` are where a launch job may start a removed app's helper from.
    func orphans(known: KnownApps, supportFolders: [String]) -> [ScanItem] {
        var items: [ScanItem] = []
        for location in Self.locations {
            for entry in entries(in: location) {
                let base = Self.baseName(entry.lastPathComponent).lowercased()
                let selected: Bool
                var label: String?
                switch location.orphans {
                case .never:
                    continue
                case .vendorGone:
                    guard known.isOrphan(base, byVendor: true) else { continue }
                    selected = false
                case .appGone(let harmless):
                    guard known.isOrphan(base, byVendor: false) else { continue }
                    selected = harmless
                case .startupItem:
                    guard let dead = orphanedStartupItem(entry, in: location, known: known, supportFolders: supportFolders) else { continue }
                    selected = dead
                    label = entry.lastPathComponent + (dead ? " (starts nothing: its program is gone)" : " (starts a removed app's helper)")
                }
                items.append(ScanItem(url: entry, size: DiskUsage.size(of: entry), category: Self.orphanCategory, isSelected: selected,
                                      label: label))
            }
        }
        return items
    }

    /// A launch job is left over when the program it starts is gone (true), unless Protection has more to
    /// say about it, or when it starts a helper from a support folder and nothing from its vendor is left
    /// (false). Nil for any other job.
    func orphanedStartupItem(_ plist: URL, in location: Location, known: KnownApps, supportFolders: [String]) -> Bool? {
        let scope: LaunchItem.Scope = location.folder == "LaunchDaemons" ? .daemon : (shared ? .globalAgent : .userAgent)
        guard plist.pathExtension == "plist", let job = LaunchItemReader.item(at: plist, scope: scope),
              let program = job.program, program.hasPrefix("/") else { return nil }
        let names = [Self.baseName(plist.lastPathComponent).lowercased(), job.label.lowercased()]
        guard !names.contains(where: Self.isMacOSName) else { return nil }
        if !FileManager.default.fileExists(atPath: program) {
            // A program on a disk that isn't plugged in isn't gone.
            guard !program.hasPrefix("/Volumes/"), PersistenceAuditor().audit([job]).isEmpty else { return nil }
            return true
        }
        let ids = names.filter(Self.looksLikeBundleID)
        guard supportFolders.contains(where: { program.hasPrefix($0 + "/") }), !ids.isEmpty,
              ids.allSatisfy({ known.isOrphan($0, byVendor: true, startupItem: true) })
        else { return nil }
        return false
    }

    /// Folders named after a vendor whose apps are all gone ("VMware", "VMware Fusion" for com.vmware), in
    /// Application Support and Preferences. Only for vendors of four letters or more; listed for you to check.
    func vendorFolders(_ vendors: Set<String>) -> [ScanItem] {
        let names = vendors.map(KnownApps.vendorName).filter { $0.count >= 4 }
        guard !names.isEmpty else { return [] }
        var items: [ScanItem] = []
        for location in Self.locations where location.folder == "Application Support" || location.folder == "Preferences" {
            for entry in entries(in: location) {
                let base = Self.baseName(entry.lastPathComponent).lowercased()
                guard names.contains(where: { base == $0 || base.hasPrefix($0 + " ") }) else { continue }
                items.append(ScanItem(url: entry, size: DiskUsage.size(of: entry), category: Self.orphanCategory, isSelected: false))
            }
        }
        return items
    }

    /// Names macOS itself uses: Apple's, and the open-source parts it ships (CUPS for printing, Kerberos…).
    static let macOSPrefixes = ["com.apple.", "org.cups.", "com.openssh.", "edu.mit.", "org.postfix.", "com.vix.", "org.openldap.",
                                "org.apache.", "org.net-snmp.", "org.ntp."]

    static func isMacOSName(_ name: String) -> Bool {
        macOSPrefixes.contains { name.hasPrefix($0) }
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
