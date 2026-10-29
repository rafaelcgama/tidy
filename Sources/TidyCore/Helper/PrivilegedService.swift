import Foundation

public enum HelperError: Error, Equatable, LocalizedError {
    case invalidBatchID(String)
    case commandFailed(command: String, status: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidBatchID(let id): return "No usable quarantine batch named \"\(id)\"."
        case .commandFailed(let command, let status): return "\(command) stopped with exit code \(status)."
        }
    }
}

/// Everything Tidy's privileged helper does, apart from XPC. Every path is checked against the
/// policy, moves never follow symlinks, and the quarantine sits in a folder only root can change.
public struct PrivilegedService: Sendable {
    public typealias Runner = @Sendable ([String]) throws -> Void

    public let policy: HelperPolicy
    public let store: QuarantineStore
    /// Who must own the quarantine folder and the folders above it (besides root).
    public let trustedOwner: UInt32
    let run: Runner

    public init(policy: HelperPolicy = .standard,
                store: QuarantineStore = QuarantineStore(root: QuarantineStore.systemRoot, mover: SecureFileOps.mover),
                trustedOwner: UInt32 = 0,
                run: @escaping Runner = PrivilegedService.runCommand) {
        self.policy = policy
        self.store = store
        self.trustedOwner = trustedOwner
        self.run = run
    }

    /// Moves the requested items into the system quarantine. Items the policy refuses are reported, never moved.
    public func quarantine(_ request: HelperQuarantineRequest, now: Date = Date()) throws -> HelperQuarantineReply {
        guard QuarantineStore.isValidBatchID(request.batchID), !store.hasBatch(request.batchID) else {
            throw HelperError.invalidBatchID(request.batchID)
        }
        try SecureFileOps.prepareTrustedFolder(store.root.path, owner: trustedOwner)
        var accepted: [ScanItem] = []
        var failed: [HelperFailure] = []
        var seen = Set<String>()
        for item in request.items {
            do {
                let target = try policy.source(item.path)
                guard seen.insert(target.path.lowercased()).inserted else { continue }
                accepted.append(ScanItem(url: URL(fileURLWithPath: target.path), size: max(0, item.size),
                                         category: String(item.category.prefix(80)), isSelected: true))
            } catch {
                failed.append(HelperFailure(path: item.path, reason: error.localizedDescription))
            }
        }
        guard !accepted.isEmpty else { return HelperQuarantineReply(batch: nil, failed: failed) }
        // A daemon stops now rather than at the next restart. Best effort: launchd may not have it loaded.
        for item in accepted where Self.isDaemon(item.url.path) {
            try? run(["/bin/launchctl", "bootout", "system", item.url.path])
        }
        let outcome = try store.quarantine(accepted, batchID: request.batchID, now: now)
        return HelperQuarantineReply(batch: outcome.batch.entries.isEmpty ? nil : outcome.batch,
                                     failed: failed + outcome.failed.map { HelperFailure(path: $0.item.url.path, reason: $0.reason) })
    }

    /// Puts a batch back. Its manifest is root's own, but every destination is checked again anyway.
    public func restore(batchID: String, now: Date = Date()) throws -> HelperRestoreReply {
        try SecureFileOps.prepareTrustedFolder(store.root.path, owner: trustedOwner)
        guard let batch = store.batches().first(where: { $0.id == batchID }) else {
            throw HelperError.invalidBatchID(batchID)
        }
        for entry in batch.entries {
            _ = try policy.destination(entry.originalPath)
        }
        let result = try store.restore(batchID: batchID, now: now)
        // A daemon that's back starts again, as it was before it was removed.
        for entry in result.restored where Self.isDaemon(entry.originalPath) {
            try? run(["/bin/launchctl", "bootstrap", "system", entry.originalPath])
        }
        return HelperRestoreReply(result)
    }

    /// A launch daemon's plist, which launchd may have loaded.
    static func isDaemon(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        return url.pathExtension == "plist" && url.deletingLastPathComponent().lastPathComponent == "LaunchDaemons"
    }

    /// Deletes system quarantine batches for good, when you ask for it before their time is up. Every
    /// id is checked first, so a request naming a batch that isn't there deletes nothing.
    @discardableResult
    public func delete(_ request: HelperDeleteRequest, now: Date = Date()) throws -> [QuarantineBatch] {
        var ids: [String] = []
        for id in request.batchIDs where !ids.contains(id) {
            guard QuarantineStore.isValidBatchID(id) else { throw HelperError.invalidBatchID(id) }
            ids.append(id)
        }
        guard let first = ids.first else { return [] }
        guard FileManager.default.fileExists(atPath: store.root.path) else { throw HelperError.invalidBatchID(first) }
        try SecureFileOps.prepareTrustedFolder(store.root.path, owner: trustedOwner)
        if let missing = ids.first(where: { !store.hasBatch($0) }) { throw HelperError.invalidBatchID(missing) }
        return try ids.map { try store.delete(batchID: $0, now: now) }
    }

    /// Deletes system quarantine batches past the retention period, as the app does with its own.
    @discardableResult
    public func purgeExpired(now: Date = Date()) throws -> [QuarantineBatch] {
        guard FileManager.default.fileExists(atPath: store.root.path) else { return [] }
        try SecureFileOps.prepareTrustedFolder(store.root.path, owner: trustedOwner)
        return try store.purgeExpired(now: now)
    }

    /// Runs a program and waits for it; a non-zero exit is an error.
    @Sendable public static func runCommand(_ command: [String]) throws {
        guard let path = command.first else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = Array(command.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let shown = ([URL(fileURLWithPath: path).lastPathComponent] + command.dropFirst()).joined(separator: " ")
            throw HelperError.commandFailed(command: shown, status: process.terminationStatus)
        }
    }
}
