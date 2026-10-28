import Foundation

/// Browser history, cookies, autofill and saved tabs, plus macOS recent items. Nothing is preselected.
/// Passwords, bookmarks, extensions and settings are never listed, and the allowlist holds only the
/// exact files below, so nothing else in a browser profile can be moved.
public struct PrivacyScanner: CleaningScanner {
    public struct Browser: Sendable, Equatable {
        public let name: String
        public let bundleID: String
        /// Where the browser keeps its profiles, relative to the home folder.
        let root: String
        let layout: Layout
    }

    enum Layout: Sendable, Equatable {
        /// Chromium: profiles are "Default" and "Profile N" folders with a Preferences file.
        case chromium
        /// Opera: the root folder is the only profile.
        case chromiumSingleProfile
        /// Firefox: every folder under Profiles with a prefs.js is a profile.
        case firefox
        /// Safari: paths are relative to the home folder.
        case safari
    }

    /// One kind of data and the files that hold it, relative to the profile folder.
    struct DataKind: Sendable {
        let title: String
        let paths: [String]
    }

    public static let browsers: [Browser] = [
        Browser(name: "Safari", bundleID: "com.apple.Safari", root: "", layout: .safari),
        Browser(name: "Google Chrome", bundleID: "com.google.Chrome", root: "Library/Application Support/Google/Chrome", layout: .chromium),
        Browser(name: "Brave", bundleID: "com.brave.Browser", root: "Library/Application Support/BraveSoftware/Brave-Browser", layout: .chromium),
        Browser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", root: "Library/Application Support/Microsoft Edge", layout: .chromium),
        Browser(name: "Arc", bundleID: "company.thebrowser.Browser", root: "Library/Application Support/Arc/User Data", layout: .chromium),
        Browser(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", root: "Library/Application Support/Vivaldi", layout: .chromium),
        Browser(name: "Chromium", bundleID: "org.chromium.Chromium", root: "Library/Application Support/Chromium", layout: .chromium),
        Browser(name: "Opera", bundleID: "com.operasoftware.Opera", root: "Library/Application Support/com.operasoftware.Opera", layout: .chromiumSingleProfile),
        Browser(name: "Firefox", bundleID: "org.mozilla.firefox", root: "Library/Application Support/Firefox/Profiles", layout: .firefox),
    ]

    static let cookies = "Cookies (signs you out of websites)"

    static let chromiumKinds = [
        DataKind(title: "Browsing and download history",
                 paths: ["History", "History-journal", "Visited Links", "Top Sites", "Top Sites-journal",
                         "Shortcuts", "Shortcuts-journal", "Network Action Predictor", "Network Action Predictor-journal"]),
        DataKind(title: cookies, paths: ["Cookies", "Cookies-journal", "Network/Cookies", "Network/Cookies-journal"]),
        DataKind(title: "Autofill (form entries, saved addresses and cards)", paths: ["Web Data", "Web Data-journal"]),
        DataKind(title: "Open and recently closed tabs", paths: ["Current Session", "Current Tabs", "Last Session", "Last Tabs", "Sessions"]),
    ]

    // Firefox keeps history in places.sqlite together with bookmarks, so history is left to Firefox itself.
    static let firefoxKinds = [
        DataKind(title: cookies, paths: ["cookies.sqlite", "cookies.sqlite-wal", "cookies.sqlite-shm"]),
        DataKind(title: "Form history", paths: ["formhistory.sqlite", "formhistory.sqlite-wal", "formhistory.sqlite-shm"]),
        DataKind(title: "Open and recently closed tabs", paths: ["sessionstore.jsonlz4", "sessionstore-backups"]),
    ]

    static let safariKinds = [
        DataKind(title: "Browsing history",
                 paths: ["Library/Safari/History.db", "Library/Safari/History.db-shm", "Library/Safari/History.db-wal", "Library/Safari/History.db-lock"]),
        DataKind(title: "Recently closed tabs", paths: ["Library/Safari/RecentlyClosedTabs.plist", "Library/Safari/LastSession.plist"]),
        DataKind(title: "Downloads list", paths: ["Library/Safari/Downloads.plist"]),
        DataKind(title: cookies, paths: ["Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"]),
    ]

    static let recentItems = DataKind(title: "Recent items (Apple menu, Finder and apps)", paths: [
        "com.apple.LSSharedFileList.RecentApplications.sfl2", "com.apple.LSSharedFileList.RecentApplications.sfl3",
        "com.apple.LSSharedFileList.RecentDocuments.sfl2", "com.apple.LSSharedFileList.RecentDocuments.sfl3",
        "com.apple.LSSharedFileList.RecentServers.sfl2", "com.apple.LSSharedFileList.RecentServers.sfl3",
        "com.apple.LSSharedFileList.RecentHosts.sfl2", "com.apple.LSSharedFileList.RecentHosts.sfl3",
        "com.apple.LSSharedFileList.ApplicationRecentDocuments",
    ])

    public let name = "Privacy"
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// Every file this scanner could list, whether it exists or not. Nothing else can be cleaned.
    public var safePaths: SafePaths {
        SafePaths(allowedRoots: candidates().map(\.url))
    }

    public func scan(progress: @Sendable (ScanProgress) -> Void) async throws -> [ScanItem] {
        var items: [ScanItem] = []
        let all = candidates()
        for (index, candidate) in all.enumerated() {
            try Task.checkCancellation()
            if index % 20 == 0 {
                progress(ScanProgress(completed: index, total: all.count, currentPath: candidate.url.path))
            }
            guard (try? FileManager.default.attributesOfItem(atPath: candidate.url.path)) != nil else { continue }
            let size = DiskUsage.size(of: candidate.url)
            guard size > 0 else { continue }
            items.append(ScanItem(url: candidate.url, size: size, category: candidate.category))
        }
        return items
    }

    /// The browsers whose data is among the items. They should be quit first, or they write it back.
    public func browsers(owning items: [ScanItem]) -> [Browser] {
        let byPath = Dictionary(candidates().compactMap { candidate in candidate.browser.map { (candidate.url.standardizedFileURL.path, $0) } },
                                uniquingKeysWith: { first, _ in first })
        let owners = Set(items.compactMap { byPath[$0.url.standardizedFileURL.path]?.bundleID })
        return Self.browsers.filter { owners.contains($0.bundleID) }
    }

    /// Safari's folder exists but can't be read: Tidy needs Full Disk Access to see Safari data.
    public var safariNeedsFullDiskAccess: Bool {
        let safari = home.appendingPathComponent("Library/Safari")
        return FileManager.default.fileExists(atPath: safari.path)
            && (try? FileManager.default.contentsOfDirectory(atPath: safari.path)) == nil
    }

    // MARK: - Candidates

    struct Candidate {
        let url: URL
        let category: String
        let browser: Browser?
    }

    func candidates() -> [Candidate] {
        var result: [Candidate] = []
        for browser in Self.browsers {
            let profiles = self.profiles(of: browser)
            for (folder, label) in profiles {
                let prefix = label.map { "\(browser.name) (\($0))" } ?? browser.name
                for kind in kinds(for: browser.layout) {
                    for path in kind.paths {
                        result.append(Candidate(url: folder.appendingPathComponent(path),
                                                category: "\(prefix): \(kind.title)", browser: browser))
                    }
                }
            }
        }
        let sharedFileList = home.appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")
        for path in Self.recentItems.paths {
            result.append(Candidate(url: sharedFileList.appendingPathComponent(path),
                                    category: "macOS: \(Self.recentItems.title)", browser: nil))
        }
        return result
    }

    func kinds(for layout: Layout) -> [DataKind] {
        switch layout {
        case .chromium, .chromiumSingleProfile: return Self.chromiumKinds
        case .firefox: return Self.firefoxKinds
        case .safari: return Self.safariKinds
        }
    }

    /// Profile folders, with a label when the browser has more than one.
    func profiles(of browser: Browser) -> [(URL, String?)] {
        let root = home.appendingPathComponent(browser.root)
        let fm = FileManager.default
        switch browser.layout {
        case .safari:
            return [(home, nil)]
        case .chromiumSingleProfile:
            return fm.fileExists(atPath: root.appendingPathComponent("Preferences").path) ? [(root, nil)] : []
        case .chromium:
            let names = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
                .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
                .filter { fm.fileExists(atPath: root.appendingPathComponent($0).appendingPathComponent("Preferences").path) }
                .sorted()
            return names.map { (root.appendingPathComponent($0), names.count > 1 ? $0 : nil) }
        case .firefox:
            let names = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
                .filter { fm.fileExists(atPath: root.appendingPathComponent($0).appendingPathComponent("prefs.js").path) }
                .sorted()
            // Folder names look like "abcd1234.default-release"; the part after the dot is the profile's name.
            return names.map { name in
                let label = name.split(separator: ".", maxSplits: 1).last.map(String.init) ?? name
                return (root.appendingPathComponent(name), names.count > 1 ? label : nil)
            }
        }
    }
}
