import Foundation

/// One item the app asks the helper to move into the system quarantine.
public struct HelperItem: Codable, Hashable, Sendable {
    public let path: String
    public let size: Int64
    public let category: String

    public init(path: String, size: Int64, category: String) {
        self.path = path
        self.size = size
        self.category = category
    }

    public init(_ item: ScanItem) {
        self.init(path: item.url.path, size: item.size, category: item.category)
    }
}

public struct HelperQuarantineRequest: Codable, Sendable {
    /// Shared with the part of the same clean the app moved itself, so one Undo restores both.
    public let batchID: String
    public let items: [HelperItem]

    public init(batchID: String, items: [HelperItem]) {
        self.batchID = batchID
        self.items = items
    }
}

public struct HelperFailure: Codable, Hashable, Sendable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct HelperQuarantineReply: Codable, Sendable {
    /// What was moved; nil when nothing was.
    public let batch: QuarantineBatch?
    public let failed: [HelperFailure]

    public init(batch: QuarantineBatch?, failed: [HelperFailure]) {
        self.batch = batch
        self.failed = failed
    }
}

public struct HelperRestoreReply: Codable, Sendable {
    public struct Skipped: Codable, Sendable {
        public let entry: QuarantineEntry
        public let reason: String
    }

    public let restored: [QuarantineEntry]
    public let skipped: [Skipped]

    public init(restored: [QuarantineEntry], skipped: [Skipped]) {
        self.restored = restored
        self.skipped = skipped
    }

    init(_ result: RestoreResult) {
        self.init(restored: result.restored, skipped: result.skipped.map { Skipped(entry: $0.entry, reason: $0.reason) })
    }
}

/// System quarantine batches to delete for good, before their time is up, all after one password prompt.
public struct HelperDeleteRequest: Codable, Sendable {
    public let batchIDs: [String]

    public init(batchIDs: [String]) {
        self.batchIDs = batchIDs
    }
}

/// JSON with ISO 8601 dates, for everything that crosses XPC.
public enum HelperCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
