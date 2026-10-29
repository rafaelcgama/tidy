import Foundation

/// Finds user-level junk: caches, logs, Xcode build products and old device support files. System Junk
/// also looks for package caches, simulators and macOS installers (see `CombinedScanner.systemJunk`).
/// The Trash is left to Finder: macOS keeps it from apps without Full Disk Access.
/// Each direct child of a junk location becomes one ScanItem, so the user can pick what to remove.
public struct SystemJunkScanner: CleaningScanner {
    public struct Location: Sendable, Hashable {
        public let category: String
        public let url: URL
        /// Whether items here start selected. Only regenerable data is preselected.
        public let selectedByDefault: Bool
        /// For caches: items written to lately start unselected anyway (see `CacheUse`).
        public let keepsItemsInUse: Bool

        public init(category: String, url: URL, selectedByDefault: Bool, keepsItemsInUse: Bool = false) {
            self.category = category
            self.url = url
            self.selectedByDefault = selectedByDefault
            self.keepsItemsInUse = keepsItemsInUse
        }
    }

    public let name = "System Junk"
    public let locations: [Location]
    /// In folders it covers, only what the admin helper would accept is offered.
    public let policy: HelperPolicy
    /// The time caches in use are measured from.
    public let now: Date

    public init(locations: [Location], policy: HelperPolicy = .standard, now: Date = Date()) {
        self.locations = locations
        self.policy = policy
        self.now = now
    }

    public static func defaultLocations(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Location] {
        let lib = home.appendingPathComponent("Library")
        let xcode = lib.appendingPathComponent("Developer/Xcode")
        return [
            Location(category: "User caches", url: lib.appendingPathComponent("Caches"), selectedByDefault: true, keepsItemsInUse: true),
            Location(category: "User logs", url: lib.appendingPathComponent("Logs"), selectedByDefault: true),
            Location(category: "Xcode DerivedData", url: xcode.appendingPathComponent("DerivedData"), selectedByDefault: true,
                     keepsItemsInUse: true),
            Location(category: "Xcode archives", url: xcode.appendingPathComponent("Archives"), selectedByDefault: false),
            Location(category: "iOS device support", url: xcode.appendingPathComponent("iOS DeviceSupport"), selectedByDefault: false),
            Location(category: "Simulator caches", url: lib.appendingPathComponent("Developer/CoreSimulator/Caches"), selectedByDefault: true,
                     keepsItemsInUse: true),
        ]
    }

    /// Junk outside your home, which usually needs the admin helper to clean. Never preselected.
    public static let systemLocations: [Location] = [
        Location(category: "System caches", url: URL(fileURLWithPath: "/Library/Caches"), selectedByDefault: false),
        Location(category: "System logs", url: URL(fileURLWithPath: "/Library/Logs"), selectedByDefault: false),
        Location(category: "System crash reports", url: URL(fileURLWithPath: "/Library/Logs/DiagnosticReports"), selectedByDefault: false),
        Location(category: "Archived system logs", url: URL(fileURLWithPath: "/private/var/log"), selectedByDefault: false),
    ]

    /// The allowlist matching these locations, for use with QuarantineCleaner.
    public var safePaths: SafePaths {
        SafePaths(allowedRoots: locations.map(\.url))
    }

    public func scan(progress: @Sendable (ScanProgress) -> Void) async throws -> [ScanItem] {
        let fm = FileManager.default
        var items: [ScanItem] = []
        for (index, location) in locations.enumerated() {
            try Task.checkCancellation()
            progress(ScanProgress(completed: index, total: locations.count, currentPath: location.url.path))
            guard let children = try? fm.contentsOfDirectory(at: location.url, includingPropertiesForKeys: nil) else { continue }
            for child in children {
                try Task.checkCancellation()
                // In system folders, only what the admin helper would accept: no live logs, nothing hidden.
                if let rule = policy.folder(for: child), !rule.accepts(name: child.lastPathComponent) { continue }
                progress(ScanProgress(completed: index, total: locations.count, currentPath: child.path))
                let usage = DiskUsage.usage(of: child)
                guard usage.size > 0 else { continue }
                let inUse = location.keepsItemsInUse && CacheUse.isInUse(lastModified: usage.lastModified, now: now)
                items.append(ScanItem(url: child, size: usage.size, category: location.category,
                                      isSelected: location.selectedByDefault && !inUse, lastModified: usage.lastModified))
            }
        }
        progress(ScanProgress(completed: locations.count, total: locations.count, currentPath: nil))
        return items.sorted { $0.size > $1.size }
    }
}
