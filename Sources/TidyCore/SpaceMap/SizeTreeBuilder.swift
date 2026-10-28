import Foundation

/// Walks a folder and builds a size tree for the space map. Read-only.
/// Keeps the `maxChildren` largest entries of each folder and merges the rest into one aggregate,
/// so huge trees stay small in memory. Doesn't follow symlinks or cross onto other volumes.
public struct SizeTreeBuilder: Sendable {
    public let maxChildren: Int

    public init(maxChildren: Int = 40) {
        self.maxChildren = max(1, maxChildren)
    }

    public func build(at root: URL, progress: @Sendable (ScanProgress) -> Void = { _ in }) async throws -> DiskNode {
        var counter = 0
        let node = try directoryNode(root, device: Self.device(of: root), counter: &counter, progress: progress)
        progress(ScanProgress(completed: counter, total: counter, currentPath: nil))
        return node
    }

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]

    private func directoryNode(_ url: URL, device: UInt64?, counter: inout Int, progress: (ScanProgress) -> Void) throws -> DiskNode {
        let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Self.keys)) ?? []
        var children: [DiskNode] = []
        children.reserveCapacity(entries.count)

        for entry in entries {
            if Task.isCancelled { throw CancellationError() }
            guard let values = try? entry.resourceValues(forKeys: Set(Self.keys)), values.isSymbolicLink != true else { continue }
            counter += 1
            if counter % 1000 == 0 {
                progress(ScanProgress(completed: counter, total: nil, currentPath: entry.path))
            }
            if values.isDirectory == true {
                if let device, let entryDevice = Self.device(of: entry), entryDevice != device { continue }
                children.append(try directoryNode(entry, device: device, counter: &counter, progress: progress))
            } else {
                let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                children.append(DiskNode(id: entry.path, url: entry, name: entry.lastPathComponent, size: size,
                                         isDirectory: false, isAggregate: false, itemCount: 1, children: []))
            }
        }

        children.sort { $0.size > $1.size }
        let total = children.reduce(0) { $0 + $1.size }
        if children.count > maxChildren {
            let rest = children[maxChildren...]
            let aggregate = DiskNode(id: url.path + "/\u{2026}", url: url, name: "\(rest.count) smaller items",
                                     size: rest.reduce(0) { $0 + $1.size },
                                     isDirectory: false, isAggregate: true, itemCount: rest.count, children: [])
            children = Array(children.prefix(maxChildren)) + [aggregate]
        }
        return DiskNode(id: url.path, url: url, name: url.lastPathComponent, size: total,
                        isDirectory: true, isAggregate: false, itemCount: 1, children: children)
    }

    /// The device a path lives on (stat's st_dev), used to stay on one volume.
    static func device(of url: URL) -> UInt64? {
        let value = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemNumber]
        if let number = value as? NSNumber { return number.uint64Value }
        if let number = value as? Int { return UInt64(number) }
        if let number = value as? UInt64 { return number }
        return nil
    }
}
