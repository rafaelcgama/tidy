import Foundation

/// A single thing a scanner found that could be cleaned.
public struct ScanItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public let size: Int64
    public let category: String
    /// Items are never selected by default unless the scanner marks them safe.
    public var isSelected: Bool
    /// When the file was last changed, for scanners where age matters.
    public let lastModified: Date?

    public init(id: UUID = UUID(), url: URL, size: Int64, category: String, isSelected: Bool = false, lastModified: Date? = nil) {
        self.id = id
        self.url = url
        self.size = size
        self.category = category
        self.isSelected = isSelected
        self.lastModified = lastModified
    }
}
