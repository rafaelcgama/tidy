import Foundation

public struct ScanProgress: Sendable {
    public let completed: Int
    public let total: Int?
    public let currentPath: String?
}

/// Scanners are async, cancellable (via Task cancellation) and report progress.
public protocol Scanner: Sendable {
    var name: String { get }
    func scan(progress: @Sendable (ScanProgress) -> Void) async throws -> [ScanItem]
}

/// A scanner whose results can be cleaned, with the allowlist that cleaning must respect.
public protocol CleaningScanner: Scanner {
    var safePaths: SafePaths { get }
}
