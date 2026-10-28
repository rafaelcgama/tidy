import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum AdminAccess {
    /// True when this process can't move the item itself (an app installed for all users, a
    /// system cache), so it needs Tidy's privileged helper.
    @Sendable public static func needsAdmin(_ url: URL) -> Bool {
        let writable: Int32 = 2  // W_OK
        let parent = url.deletingLastPathComponent().path
        guard access(parent, writable) == 0 else { return true }
        guard let folder = SecureFileOps.entryInfo(parent, followingLinks: true),
              let item = SecureFileOps.entryInfo(url.path) else { return false }
        let me = UInt32(geteuid())
        // In a sticky folder such as /Library/Caches, only an entry's owner (or the folder's) may move it.
        if folder.isSticky, item.owner != me, folder.owner != me { return true }
        // Moving a folder to another folder rewrites its "..", which needs write access to the folder.
        if item.isDirectory, !item.isSymlink, access(url.path, writable) != 0 { return true }
        return false
    }
}

/// Moves what this process can into the user's quarantine and hands root-owned items to the
/// privileged helper. Both halves share one batch id, so one Undo puts everything back.
public struct AdminAwareCleaner: Cleaner {
    /// What the app asks of root: over XPC from the admin helper, or from Tidy itself run as root
    /// after macOS asks for an administrator's password.
    public struct HelperLink: Sendable {
        public let quarantine: @Sendable (HelperQuarantineRequest) async throws -> HelperQuarantineReply
        public let restore: @Sendable (String) async throws -> HelperRestoreReply
        /// Deletes these system quarantine batches for good.
        public let delete: @Sendable ([String]) async throws -> Void

        public init(quarantine: @escaping @Sendable (HelperQuarantineRequest) async throws -> HelperQuarantineReply,
                    restore: @escaping @Sendable (String) async throws -> HelperRestoreReply,
                    delete: @escaping @Sendable ([String]) async throws -> Void) {
            self.quarantine = quarantine
            self.restore = restore
            self.delete = delete
        }
    }

    public static let helperMissing = "needs administrator rights: install Tidy's admin helper in Settings"

    /// Part of a batch belongs to the system, and there's no way to act as root.
    public struct NeedsAdmin: Error, LocalizedError {
        public var errorDescription: String? { "Part of this belongs to the system, so it " + AdminAwareCleaner.helperMissing + "." }
    }

    public let user: QuarantineCleaner
    /// The helper's quarantine, read here only to see which batches it holds.
    public let systemStore: QuarantineStore
    public let needsAdmin: @Sendable (URL) -> Bool
    /// Nil when there's no way to act as root; root-owned items are then skipped, with the reason.
    public let helper: HelperLink?
    /// Stops a launch agent before its plist moves (and again if it didn't), and starts it once it's back.
    public let changeAgent: @Sendable (_ plist: URL, _ start: Bool) -> Void

    public init(user: QuarantineCleaner,
                systemStore: QuarantineStore = QuarantineStore(root: QuarantineStore.systemRoot),
                needsAdmin: @escaping @Sendable (URL) -> Bool = AdminAccess.needsAdmin,
                helper: HelperLink?,
                changeAgent: @escaping @Sendable (_ plist: URL, _ start: Bool) -> Void = LaunchJobControl.changeAgent) {
        self.user = user
        self.systemStore = systemStore
        self.needsAdmin = needsAdmin
        self.helper = helper
        self.changeAgent = changeAgent
    }

    public func clean(_ items: [ScanItem], dryRun: Bool) async throws -> CleanResult {
        let screened = try user.screen(items)
        var skipped = screened.skipped
        var own: [ScanItem] = []
        var admin: [ScanItem] = []
        for item in screened.accepted {
            if !needsAdmin(item.url) {
                own.append(item)
            } else if helper != nil {
                admin.append(item)
            } else {
                skipped.append((item, Self.helperMissing))
            }
        }
        if dryRun {
            return CleanResult(removed: own + admin, skipped: skipped, batch: nil)
        }

        let now = Date()
        let batchID = QuarantineStore.makeBatchID(now)
        var removed: [ScanItem] = []
        var entries: [QuarantineEntry] = []
        if !own.isEmpty {
            for item in own { changeAgent(item.url, false) }
            let outcome = try user.store.quarantine(own, batchID: batchID, now: now)
            let moved = Set(outcome.batch.entries.map(\.originalPath))
            removed += own.filter { moved.contains($0.url.path) }
            entries += outcome.batch.entries
            skipped += outcome.failed
            for failure in outcome.failed { changeAgent(failure.item.url, true) }
        }
        if let helper, !admin.isEmpty {
            for item in admin { changeAgent(item.url, false) }
            do {
                let reply = try await helper.quarantine(HelperQuarantineRequest(batchID: batchID, items: admin.map(HelperItem.init)))
                let movedEntries = reply.batch?.entries ?? []
                let moved = Set(movedEntries.map { HelperPolicy.canonical($0.originalPath) })
                let reasons = Dictionary(reply.failed.map { (HelperPolicy.canonical($0.path), $0.reason) }, uniquingKeysWith: { first, _ in first })
                for item in admin {
                    let path = HelperPolicy.canonical(item.url.path)
                    if moved.contains(path) {
                        removed.append(item)
                    } else {
                        skipped.append((item, reasons[path] ?? "not moved"))
                        changeAgent(item.url, true)
                    }
                }
                entries += movedEntries
            } catch {
                // What this process moved stays moved, and undoable; the helper's part is reported.
                skipped += admin.map { ($0, error.localizedDescription) }
                for item in admin { changeAgent(item.url, true) }
            }
        }
        let batch = entries.isEmpty ? nil : QuarantineBatch(id: batchID, date: now, entries: entries)
        return CleanResult(removed: removed, skipped: skipped, batch: batch)
    }

    /// Every batch either quarantine holds, newest first. A clean split between the two is one batch.
    public func batches() -> [QuarantineBatch] {
        var merged: [String: QuarantineBatch] = [:]
        for batch in user.store.batches() + systemStore.batches() {
            if var existing = merged[batch.id] {
                existing.entries += batch.entries
                merged[batch.id] = existing
            } else {
                merged[batch.id] = batch
            }
        }
        return merged.values.sorted { $0.date > $1.date }
    }

    /// Deletes batches for good from whichever quarantines hold them, before their time is up; none
    /// of it can be put back after. The system's part goes first, in one request, so when it fails
    /// (the password prompt is cancelled, say) nothing is deleted.
    @discardableResult
    public func delete(batchIDs: [String]) async throws -> [QuarantineBatch] {
        let wanted = Set(batchIDs)
        let held = batches().filter { wanted.contains($0.id) }
        if let missing = wanted.subtracting(held.map(\.id)).sorted().first {
            throw QuarantineError.invalidBatchID(missing)
        }
        let system = held.map(\.id).filter(systemStore.hasBatch)
        if !system.isEmpty {
            guard let helper else { throw NeedsAdmin() }
            try await helper.delete(system)
        }
        for batch in held where user.store.hasBatch(batch.id) {
            try user.store.delete(batchID: batch.id)
        }
        return held
    }

    /// Puts a batch back from whichever quarantines hold it.
    public func undo(batchID: String) async throws -> RestoreResult {
        let inUser = user.store.hasBatch(batchID)
        let systemEntries = systemStore.batches().first { $0.id == batchID }?.entries
        guard inUser || systemEntries != nil else { throw QuarantineError.invalidBatchID(batchID) }

        var restored: [QuarantineEntry] = []
        var skipped: [(entry: QuarantineEntry, reason: String)] = []
        if inUser {
            let result = try user.store.restore(batchID: batchID)
            for entry in result.restored { changeAgent(URL(fileURLWithPath: entry.originalPath), true) }
            restored += result.restored
            skipped += result.skipped
        }
        if let systemEntries {
            if let helper {
                do {
                    let reply = try await helper.restore(batchID)
                    for entry in reply.restored { changeAgent(URL(fileURLWithPath: entry.originalPath), true) }
                    restored += reply.restored
                    skipped += reply.skipped.map { ($0.entry, $0.reason) }
                } catch {
                    skipped += systemEntries.map { ($0, error.localizedDescription) }
                }
            } else {
                skipped += systemEntries.map { ($0, Self.helperMissing) }
            }
        }
        return RestoreResult(restored: restored, skipped: skipped)
    }
}
