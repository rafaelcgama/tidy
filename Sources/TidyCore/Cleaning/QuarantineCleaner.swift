import Foundation

/// Moves selected items into the app-managed quarantine instead of deleting them,
/// so every clean is reversible for the retention period.
public struct QuarantineCleaner: Cleaner {
    public let store: QuarantineStore
    public let safePaths: SafePaths

    public init(store: QuarantineStore, safePaths: SafePaths) {
        self.store = store
        self.safePaths = safePaths
    }

    public init(quarantineRoot: URL, safePaths: SafePaths) {
        self.init(store: QuarantineStore(root: quarantineRoot), safePaths: safePaths)
    }

    public func clean(_ items: [ScanItem], dryRun: Bool) async throws -> CleanResult {
        let (accepted, skipped) = try screen(items)
        guard !dryRun, !accepted.isEmpty else {
            return CleanResult(removed: dryRun ? accepted : [], skipped: skipped, batch: nil)
        }
        let outcome = try store.quarantine(accepted)
        let movedPaths = Set(outcome.batch.entries.map(\.originalPath))
        return CleanResult(removed: accepted.filter { movedPaths.contains($0.url.path) },
                           skipped: skipped + outcome.failed,
                           batch: outcome.batch.entries.isEmpty ? nil : outcome.batch)
    }

    /// The selected items cleaning may move; anything outside the allowlist or no longer there is skipped.
    func screen(_ items: [ScanItem]) throws -> (accepted: [ScanItem], skipped: [(item: ScanItem, reason: String)]) {
        var accepted: [ScanItem] = []
        var skipped: [(item: ScanItem, reason: String)] = []
        for item in items where item.isSelected {
            try Task.checkCancellation()
            guard safePaths.permits(item.url) else {
                skipped.append((item, "outside allowlist"))
                continue
            }
            guard store.exists(item.url) else {
                skipped.append((item, "missing"))
                continue
            }
            accepted.append(item)
        }
        return (accepted, skipped)
    }
}
