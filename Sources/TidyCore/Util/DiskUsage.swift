import Foundation

enum DiskUsage {
    /// Allocated size of a file, or the sum of everything under a directory. Does not follow symlinks.
    static func size(of url: URL) -> Int64 {
        usage(of: url).size
    }

    /// The size as in `size(of:)`, and the newest modification date of the item or anything under it:
    /// when it was last written to.
    static func usage(of url: URL) -> (size: Int64, lastModified: Date?) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                         .contentModificationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return (0, nil) }
        if values.isSymbolicLink == true { return (0, nil) }
        var newest = values.contentModificationDate
        if values.isDirectory != true {
            return (Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0), newest)
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return (0, newest) }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            guard let v = try? child.resourceValues(forKeys: keys), v.isSymbolicLink != true else { continue }
            if let date = v.contentModificationDate, date > newest ?? .distantPast { newest = date }
            guard v.isDirectory != true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return (total, newest)
    }
}
