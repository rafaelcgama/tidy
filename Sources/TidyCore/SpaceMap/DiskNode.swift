import Foundation

/// A file or folder in the space map, with its total allocated size.
public struct DiskNode: Identifiable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let size: Int64
    public let isDirectory: Bool
    /// Stands for several small items merged into one block.
    public let isAggregate: Bool
    /// How many items an aggregate stands for; 1 otherwise.
    public let itemCount: Int
    /// Largest first.
    public let children: [DiskNode]
}
