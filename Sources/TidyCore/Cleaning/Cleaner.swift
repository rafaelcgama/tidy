import Foundation

public struct CleanResult: Sendable {
    /// What was moved to quarantine, or with a dry run, what would be.
    public let removed: [ScanItem]
    public let skipped: [(item: ScanItem, reason: String)]
    /// The quarantine batch holding the removed items; nil for a dry run or when nothing moved.
    public let batch: QuarantineBatch?

    public var freedBytes: Int64 { removed.reduce(0) { $0 + $1.size } }
}

public protocol Cleaner: Sendable {
    /// With dryRun true, nothing on disk changes; the result lists what would happen.
    func clean(_ items: [ScanItem], dryRun: Bool) async throws -> CleanResult
}
