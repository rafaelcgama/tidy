import Foundation

/// The Trash in your home folder. Emptying it deletes what's in it for good, as Finder's Empty Trash
/// does: those files were already deleted once, so they don't wait in quarantine again. Each time is
/// logged in `trash-log.jsonl` (paths and sizes).
public struct Trash: Sendable {
    public struct Skipped: Sendable {
        public let item: ScanItem
        public let reason: String
    }

    public struct Result: Sendable {
        public let deleted: [ScanItem]
        public let skipped: [Skipped]
    }

    public let folder: URL
    public let log: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        folder = home.appendingPathComponent(".Trash")
        log = home.appendingPathComponent("Library/Application Support/Tidy/trash-log.jsonl")
    }

    /// What's in the Trash, largest first. Nil when macOS doesn't let Tidy look: it needs Full Disk Access.
    public func items() -> [ScanItem]? {
        let fm = FileManager.default
        let children: [URL]
        do {
            children = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        } catch {
            // No Trash folder yet just means nothing was ever thrown away.
            return fm.fileExists(atPath: folder.path) ? nil : []
        }
        return children.filter { $0.lastPathComponent != ".DS_Store" }
            .map { child in
                let usage = DiskUsage.usage(of: child)
                return ScanItem(url: child, size: usage.size, category: "Trash", isSelected: true, lastModified: usage.lastModified)
            }
            .sorted { $0.size > $1.size }
    }

    /// Deletes the items for good. Anything that isn't directly in the Trash is refused. It logs a line
    /// before anything is deleted (no log, nothing deleted) and one with the outcome.
    public func empty(_ items: [ScanItem]) throws -> Result {
        try appendLog(LogLine(date: Date(), action: "start", paths: items.map(\.url.path), failed: [], bytes: items.totalSize))
        let trash = folder.resolvingSymlinksInPath().path
        var deleted: [ScanItem] = []
        var skipped: [Skipped] = []
        for item in items {
            let url = item.url
            // Only the folder is resolved: an item that is itself a symlink is deleted, not what it points to.
            // (Standardizing the URL would resolve it on Linux.)
            guard !url.pathComponents.contains(".."), url.lastPathComponent != ".",
                  url.deletingLastPathComponent().resolvingSymlinksInPath().path == trash else {
                skipped.append(Skipped(item: item, reason: "It isn't in the Trash."))
                continue
            }
            do {
                try FileManager.default.removeItem(at: url)
                deleted.append(item)
            } catch {
                skipped.append(Skipped(item: item, reason: error.localizedDescription))
            }
        }
        try? appendLog(LogLine(date: Date(), action: "deleted", paths: deleted.map(\.url.path),
                               failed: skipped.map { "\($0.item.url.path): \($0.reason)" }, bytes: deleted.totalSize))
        return Result(deleted: deleted, skipped: skipped)
    }

    struct LogLine: Codable {
        let date: Date
        /// "start" with what was chosen, then "deleted" with what is gone.
        let action: String
        let paths: [String]
        let failed: [String]
        let bytes: Int64
    }

    private func appendLog(_ line: LogLine) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        var data = try encoder.encode(line)
        data.append(0x0A)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: log) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: log)
        }
    }
}
