import Foundation

/// One item inside a quarantine batch.
public struct QuarantineEntry: Codable, Hashable, Sendable {
    public let originalPath: String
    /// Path relative to the batch folder.
    public let storedPath: String
    public let size: Int64
    public let category: String
}

/// Everything one clean moved into quarantine. Its manifest doubles as the record of what was removed.
public struct QuarantineBatch: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let date: Date
    public internal(set) var entries: [QuarantineEntry]

    public var totalSize: Int64 { entries.reduce(0) { $0 + $1.size } }
}

public struct RestoreResult: Sendable {
    public let restored: [QuarantineEntry]
    public let skipped: [(entry: QuarantineEntry, reason: String)]
}

public enum QuarantineError: Error, LocalizedError {
    case invalidBatchID(String)
    case duplicateBatchID(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBatchID(let id): return "No quarantine batch named \"\(id)\"."
        case .duplicateBatchID(let id): return "A quarantine batch named \"\(id)\" already exists."
        }
    }
}

/// App-managed quarantine: cleaned items wait here for `retentionDays` before they are deleted for good,
/// or until you delete a batch sooner. Every move in, restore, purge and deletion is appended to `history.jsonl`.
public struct QuarantineStore: @unchecked Sendable {
    /// Moves one item. The default is FileManager's move; the privileged helper passes one that never follows symlinks.
    public typealias Mover = @Sendable (_ source: URL, _ destination: URL) throws -> Void

    public let root: URL
    public let retentionDays: Int
    let fileManager: FileManager
    let mover: Mover?

    public init(root: URL, retentionDays: Int = 30, fileManager: FileManager = .default, mover: Mover? = nil) {
        self.root = root
        self.retentionDays = retentionDays
        self.fileManager = fileManager
        self.mover = mover
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tidy/Quarantine")
    }

    /// Where the privileged helper keeps what it moves. Only root can change it; the app can read the manifests.
    public static var systemRoot: URL {
        URL(fileURLWithPath: "/Library/Application Support/Tidy/Quarantine")
    }

    /// Moves items into a new batch. An item that can't be moved is reported in `failed`, not fatal.
    /// `batchID` lets two stores hold the halves of one clean under the same id.
    public func quarantine(_ items: [ScanItem], batchID: String? = nil, now: Date = Date()) throws -> (batch: QuarantineBatch, failed: [(item: ScanItem, reason: String)]) {
        let id = batchID ?? Self.makeBatchID(now)
        guard Self.isValidBatchID(id) else { throw QuarantineError.invalidBatchID(id) }
        let batchURL = root.appendingPathComponent(id)
        guard !exists(batchURL) else { throw QuarantineError.duplicateBatchID(id) }
        try fileManager.createDirectory(at: batchURL, withIntermediateDirectories: true)

        let planned = items.enumerated().map { index, item in
            QuarantineEntry(originalPath: item.url.path,
                            storedPath: "items/\(index)/\(item.url.lastPathComponent)",
                            size: item.size,
                            category: item.category)
        }
        var batch = QuarantineBatch(id: id, date: now, entries: planned)
        // Write the plan first so a crash part-way still leaves a manifest that restore can follow.
        try writeManifest(batch)

        var moved: [QuarantineEntry] = []
        var failed: [(item: ScanItem, reason: String)] = []
        for (item, entry) in zip(items, planned) {
            if Task.isCancelled {
                failed.append((item, "cancelled"))
                continue
            }
            let destination = batchURL.appendingPathComponent(entry.storedPath)
            do {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try move(item.url, to: destination)
                moved.append(entry)
            } catch {
                failed.append((item, error.localizedDescription))
            }
        }

        batch.entries = moved
        if moved.isEmpty {
            try fileManager.removeItem(at: batchURL)
        } else {
            try writeManifest(batch)
            try appendHistory(action: "quarantined", batchID: id, entries: moved, now: now)
        }
        return (batch, failed)
    }

    /// Whether this store holds a batch with this id.
    public func hasBatch(_ id: String) -> Bool {
        guard let folder = try? folder(forBatchID: id) else { return false }
        return exists(folder.appendingPathComponent("manifest.json"))
    }

    /// All batches currently held, newest first.
    public func batches() -> [QuarantineBatch] {
        guard let folders = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return folders.compactMap { try? readManifest(in: $0) }.sorted { $0.date > $1.date }
    }

    /// Moves a batch's items back to where they came from. Never overwrites something that now exists there.
    public func restore(batchID: String, now: Date = Date()) throws -> RestoreResult {
        let batchURL = try folder(forBatchID: batchID)
        let batch = try readManifest(in: batchURL)

        var restored: [QuarantineEntry] = []
        var skipped: [(entry: QuarantineEntry, reason: String)] = []
        for entry in batch.entries {
            let stored = batchURL.appendingPathComponent(entry.storedPath)
            let original = URL(fileURLWithPath: entry.originalPath)
            guard !entry.storedPath.split(separator: "/").contains(".."), exists(stored) else {
                skipped.append((entry, "no longer in quarantine"))
                continue
            }
            guard !exists(original) else {
                skipped.append((entry, "something new already exists at \(entry.originalPath)"))
                continue
            }
            do {
                try fileManager.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try move(stored, to: original)
                restored.append(entry)
            } catch {
                skipped.append((entry, error.localizedDescription))
            }
        }

        var remaining = batch
        remaining.entries = batch.entries.filter { exists(batchURL.appendingPathComponent($0.storedPath)) }
        if remaining.entries.isEmpty {
            try fileManager.removeItem(at: batchURL)
        } else {
            try writeManifest(remaining)
        }
        try appendHistory(action: "restored", batchID: batchID, entries: restored, now: now)
        return RestoreResult(restored: restored, skipped: skipped)
    }

    /// Permanently deletes batches older than the retention period.
    /// Apart from `delete(batchID:)`, which you ask for, and the Shredder, this is the only place Tidy deletes anything for good.
    @discardableResult
    public func purgeExpired(now: Date = Date()) throws -> [QuarantineBatch] {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        var purged: [QuarantineBatch] = []
        for batch in batches() where batch.date < cutoff {
            try fileManager.removeItem(at: try folder(forBatchID: batch.id))
            try appendHistory(action: "purged", batchID: batch.id, entries: batch.entries, now: now)
            purged.append(batch)
        }
        return purged
    }

    /// Permanently deletes one batch before its time is up, when you ask for it. Nothing in it can be put back after.
    @discardableResult
    public func delete(batchID: String, now: Date = Date()) throws -> QuarantineBatch {
        let batchURL = try folder(forBatchID: batchID)
        let batch = try readManifest(in: batchURL)
        try fileManager.removeItem(at: batchURL)
        try appendHistory(action: "deleted", batchID: batchID, entries: batch.entries, now: now)
        return batch
    }

    // MARK: - Internals

    private func move(_ source: URL, to destination: URL) throws {
        if let mover {
            try mover(source, destination)
        } else {
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    /// True if anything (including a broken symlink) is at `url`.
    func exists(_ url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private func folder(forBatchID id: String) throws -> URL {
        guard !id.isEmpty, !id.hasPrefix("."), !id.contains("/") else { throw QuarantineError.invalidBatchID(id) }
        return root.appendingPathComponent(id)
    }

    private func readManifest(in folder: URL) throws -> QuarantineBatch {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let batch = try decoder.decode(QuarantineBatch.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        // A manifest only counts for the folder it names; anything else is ignored rather than trusted.
        guard batch.id == folder.lastPathComponent else { throw QuarantineError.invalidBatchID(batch.id) }
        return batch
    }

    private func writeManifest(_ batch: QuarantineBatch) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(batch).write(to: root.appendingPathComponent(batch.id).appendingPathComponent("manifest.json"), options: .atomic)
    }

    struct HistoryLine: Codable {
        let date: Date
        let action: String
        let batch: String
        let path: String
        let size: Int64
    }

    private func appendHistory(action: String, batchID: String, entries: [QuarantineEntry], now: Date) throws {
        guard !entries.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        var data = Data()
        for entry in entries {
            data.append(try encoder.encode(HistoryLine(date: now, action: action, batch: batchID, path: entry.originalPath, size: entry.size)))
            data.append(0x0A)
        }
        let url = root.appendingPathComponent("history.jsonl")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url)
        }
    }

    /// Batch ids look like 20261028-101500-1A2B3C4D: the UTC time, then random hex.
    public static func isValidBatchID(_ id: String) -> Bool {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 8, parts[1].count == 6, parts[2].count == 8 else { return false }
        return parts[0].allSatisfy { $0.isASCII && $0.isNumber }
            && parts[1].allSatisfy { $0.isASCII && $0.isNumber }
            && parts[2].allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    static func makeBatchID(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date) + "-" + UUID().uuidString.prefix(8)
    }
}
