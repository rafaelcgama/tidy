import Foundation

/// What a Smart Care run found. Nothing has been changed when this is returned.
public struct SmartCareReport: Sendable {
    /// Cleanup candidates from every cleanup scanner, without overlaps. Preselected items are what "Clean" removes.
    public let cleanup: [ScanItem]
    /// The union of the scanners' allowlists; cleaning the report must use it.
    public let safePaths: SafePaths
    public let findings: [Finding]

    public var selectedCleanup: [ScanItem] { cleanup.filter(\.isSelected) }
}

/// One pass over cleanup and protection, combined into a single report before anything changes.
public struct SmartCare: Sendable {
    public let cleanupScanners: [any CleaningScanner]
    public let audit: @Sendable () -> [Finding]

    public init(cleanupScanners: [any CleaningScanner], audit: @escaping @Sendable () -> [Finding]) {
        self.cleanupScanners = cleanupScanners
        self.audit = audit
    }

    /// System junk, package caches, and the launch-job and browser-policy checks.
    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                systemLocations: [SystemJunkScanner.Location] = SystemJunkScanner.systemLocations,
                                applicationFolders: [URL] = MacInstallerScanner.defaultFolders) -> SmartCare {
        SmartCare(cleanupScanners: [
            CombinedScanner.systemJunk(home: home, systemLocations: systemLocations, applicationFolders: applicationFolders),
            DeveloperJunkScanner(home: home, projectRoots: []),
        ], audit: {
            let items = LaunchItemReader.items(in: LaunchItemReader.defaultFolders(home: home))
            return PersistenceAuditor().audit(items) + BrowserPolicyAuditor().audit()
        })
    }

    public func run(step: @Sendable (String) -> Void = { _ in }) async throws -> SmartCareReport {
        var items: [ScanItem] = []
        var safePaths = SafePaths(allowedRoots: [])
        for scanner in cleanupScanners {
            try Task.checkCancellation()
            step("Looking for \(scanner.name.lowercased())…")
            items += try await scanner.scan { _ in }
            safePaths = safePaths.merging(scanner.safePaths)
        }
        try Task.checkCancellation()
        step("Checking login items and browser settings…")
        let findings = audit()
        return SmartCareReport(cleanup: Self.withoutOverlaps(items), safePaths: safePaths, findings: findings)
    }

    /// Drops items that are the same as, or inside, another item, so nothing is counted or moved twice.
    /// When the same path appears twice, the first one wins.
    static func withoutOverlaps(_ items: [ScanItem]) -> [ScanItem] {
        let ordered = items.enumerated().sorted { lhs, rhs in
            let left = lhs.element.url.standardizedFileURL.path.count
            let right = rhs.element.url.standardizedFileURL.path.count
            return left != right ? left < right : lhs.offset < rhs.offset
        }
        var kept: [ScanItem] = []
        var keptPaths: [String] = []
        for (_, item) in ordered {
            let path = item.url.standardizedFileURL.path
            if keptPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
            kept.append(item)
            keptPaths.append(path)
        }
        return kept.sorted { $0.size > $1.size }
    }
}
