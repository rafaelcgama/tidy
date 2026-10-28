import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Overwrites files with random data and deletes them, for the few files you want gone for good.
/// It is the one part of Tidy that can't be undone: nothing goes to quarantine. It touches only what
/// it's handed, never a path Tidy refuses elsewhere (nor a folder holding one), never follows a
/// symlink and never leaves the disk a folder is on. Every run is logged (paths and sizes, never
/// contents).
public struct Shredder: Sendable {
    /// What shredding a selection would destroy, shown before anything happens.
    public struct Plan: Sendable {
        /// The chosen items Shredder accepts.
        public let accepted: [URL]
        public let refused: [Refusal]
        /// Files and links inside the accepted items, counting the items themselves.
        public let fileCount: Int
        public let folderCount: Int
        public let totalBytes: Int64
    }

    public struct Refusal: Sendable, Hashable {
        public let url: URL
        public let reason: String
    }

    public struct Result: Sendable {
        /// Chosen items that are gone.
        public let shredded: [URL]
        public let failed: [Refusal]
        public let bytesOverwritten: Int64
    }

    struct Failure: Error {
        let reason: String
    }

    /// Paths it refuses, with everything inside them.
    public let forbidden: [URL]
    /// Paths it refuses as a whole (a volume, the home folder), though what's inside may be chosen.
    public let refusedExactly: [URL]
    public let log: URL

    public init(forbidden: [URL] = Shredder.defaultForbidden,
                refusedExactly: [URL] = Shredder.defaultRefusedExactly,
                log: URL = Shredder.defaultLog) {
        self.forbidden = forbidden.map { URL(fileURLWithPath: Self.normalized($0.path)) }
        self.refusedExactly = refusedExactly.map { URL(fileURLWithPath: Self.normalized($0.path)) }
        self.log = log
    }

    /// What Tidy never touches, plus Tidy's own folders: shredding inside the quarantine would
    /// break Put Back, and the log has to stay.
    public static var defaultForbidden: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return SafePaths.defaultForbidden + [
            home.appendingPathComponent("Library/Application Support/Tidy"),
            URL(fileURLWithPath: "/Library/Application Support/Tidy"),
            // Mail's data outside ~/Library/Mail, and the system's keychains.
            home.appendingPathComponent("Library/Containers/com.apple.mail"),
            home.appendingPathComponent("Library/Group Containers/group.com.apple.mail"),
            URL(fileURLWithPath: "/Library/Keychains"),
            URL(fileURLWithPath: "/usr"), URL(fileURLWithPath: "/bin"), URL(fileURLWithPath: "/sbin"),
            URL(fileURLWithPath: "/private/etc"), URL(fileURLWithPath: "/private/var/db"),
        ]
    }

    public static var defaultRefusedExactly: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["/", "/Applications", "/Library", "/Users", "/Volumes", "/private", "/private/var", "/private/tmp", "/Users/Shared"]
            .map { URL(fileURLWithPath: $0) }
            + [home, home.appendingPathComponent("Library")]
    }

    /// Kinds of item Tidy never touches wherever they are: Photos libraries and keychains.
    static let protectedExtensions: Set<String> = ["photoslibrary", "keychain", "keychain-db"]

    public static var defaultLog: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tidy/shred-log.jsonl")
    }

    // MARK: - Planning

    public func plan(_ urls: [URL]) -> Plan {
        var accepted: [URL] = []
        var refused: [Refusal] = []
        var files = 0, folders = 0
        var bytes: Int64 = 0
        let forbidden = forbiddenPaths()
        for url in Self.withoutNested(urls) {
            if let reason = refusal(for: url) {
                refused.append(Refusal(url: url, reason: reason))
                continue
            }
            var counts = (files: 0, folders: 0, bytes: Int64(0))
            var held: String?
            walk(realLocation(of: url), forbidden: forbidden) { entry in
                switch entry {
                case .file(_, let size):
                    counts.files += 1
                    counts.bytes += size
                case .link:
                    counts.files += 1
                case .folder:
                    counts.folders += 1
                case .protected(let path):
                    held = held ?? path
                }
            }
            if let held {
                refused.append(Refusal(url: url, reason: Self.holdsProtected(held)))
                continue
            }
            accepted.append(url)
            files += counts.files
            folders += counts.folders
            bytes += counts.bytes
        }
        return Plan(accepted: accepted, refused: refused, fileCount: files, folderCount: folders, totalBytes: bytes)
    }

    /// Why an item can't be shredded, or nil if it can.
    public func refusal(for url: URL) -> String? {
        let path = Self.normalized(url.path)
        guard path.hasPrefix("/") else { return "Not a full path." }
        guard path != "/" else { return "Too broad to shred. Choose the files or folders inside it instead." }
        guard let info = SecureFileOps.entryInfo(path) else { return "It isn't there any more." }
        // Judge where it really is too: a path through a symlinked folder could lead into a refused one.
        let candidates = [path, Self.realLocation(of: path, isSymlink: info.isSymlink)]
        let forbidden = forbiddenPaths()
        if candidates.contains(where: { Self.isInside($0, forbidden) }) {
            return "Tidy never touches this folder."
        }
        if candidates.contains(where: { candidate in refusedExactly.contains { $0.path == candidate } || Self.isVolumeRoot(candidate) }) {
            return "Too broad to shred. Choose the files or folders inside it instead."
        }
        if candidates.contains(where: Self.isProtectedKind) {
            return "Tidy never touches Photos libraries or keychains."
        }
        if info.isProtectedByFlags { return "It's locked or protected by macOS." }
        return nil
    }

    /// The forbidden folders as named and, where that differs, where they really are.
    private func forbiddenPaths() -> [String] {
        forbidden.flatMap { url -> [String] in
            guard let real = SecureFileOps.realPath(url.path), real != url.path else { return [url.path] }
            return [url.path, real]
        }
    }

    static func isInside(_ path: String, _ roots: [String]) -> Bool {
        roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// A Photos library or a keychain, by its name.
    static func isProtectedKind(_ path: String) -> Bool {
        guard let name = path.split(separator: "/").last, let dot = name.lastIndex(of: ".") else { return false }
        return protectedExtensions.contains(name[name.index(after: dot)...].lowercased())
    }

    static func holdsProtected(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shown = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        return "It holds \(shown), which Tidy never touches. Choose the other things inside it instead."
    }

    /// Where an item really is: symlinked folders on the way are resolved, the item itself is left as
    /// it is (a symlink is removed, never followed).
    static func realLocation(of path: String, isSymlink: Bool) -> String {
        guard isSymlink else { return SecureFileOps.realPath(path) ?? path }
        let slash = path.lastIndex(of: "/") ?? path.startIndex
        let parent = slash == path.startIndex ? "/" : String(path[..<slash])
        guard let realParent = SecureFileOps.realPath(parent) else { return path }
        return (realParent == "/" ? "" : realParent) + "/" + path[path.index(after: slash)...]
    }

    private func realLocation(of url: URL) -> String {
        let path = Self.normalized(url.path)
        return Self.realLocation(of: path, isSymlink: SecureFileOps.entryInfo(path)?.isSymlink == true)
    }

    static func isVolumeRoot(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        return parts.count == 2 && parts[0] == "Volumes"
    }

    /// The path with "." and ".." worked out by name alone. Symlinks are left as they are; `refusal`
    /// looks at where they lead.
    static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." { _ = parts.popLast() } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Drops items inside other chosen items, so nothing is counted or shredded twice.
    static func withoutNested(_ urls: [URL]) -> [URL] {
        let paths = urls.map { normalized($0.path) }
        var seen = Set<String>()
        return zip(urls, paths).compactMap { _, path in
            guard seen.insert(path).inserted,
                  !paths.contains(where: { $0 != path && path.hasPrefix($0 == "/" ? "/" : $0 + "/") }) else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    enum Entry {
        case file(String, size: Int64)
        /// Removed without being written to: symlinks, files only in iCloud, sockets and the like.
        case link(String)
        case folder(String)
        /// Something Tidy never touches: not entered, never removed.
        case protected(String)
    }

    /// Everything under `path`, folders after their contents. Symlinks are reported, never followed,
    /// and nothing on another disk (a volume mounted inside) is entered.
    private func walk(_ path: String, forbidden: [String], device: Int64? = nil, _ visit: (Entry) -> Void) {
        var raw = stat()
        guard lstat(path, &raw) == 0 else { return }
        let info = SecureFileOps.EntryInfo(raw)
        let dev = Int64(truncatingIfNeeded: raw.st_dev)
        if let device, device != dev { return }
        if Self.isInside(path, forbidden) || Self.isProtectedKind(path) {
            visit(.protected(path))
            return
        }
        if info.isSymlink {
            visit(.link(path))
        } else if info.isDirectory {
            let children = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            for child in children.sorted() {
                walk(path + "/" + child, forbidden: forbidden, device: dev, visit)
            }
            visit(.folder(path))
        } else if UInt32(raw.st_mode) & 0o170000 == 0o100000, info.flags & 0x4000_0000 == 0 {
            visit(.file(path, size: Int64(raw.st_size)))
        } else {
            // A file only in iCloud (SF_DATALESS) has no data here to overwrite, and opening it would
            // download it. Sockets, pipes and devices are never written to.
            visit(.link(path))
        }
    }

    // MARK: - Shredding

    /// Overwrites and deletes each item. `progress` gets the bytes overwritten so far. The log gets
    /// a line before anything happens (no log, no shredding) and one with the outcome.
    public func shred(_ urls: [URL], progress: (Int64) -> Void = { _ in }) throws -> Result {
        let items = Self.withoutNested(urls)
        try appendLog(LogLine(date: Date(), action: "start", paths: items.map(\.path), failed: [], bytes: 0))
        var shredded: [URL] = []
        var failed: [Refusal] = []
        var written: Int64 = 0
        let forbidden = forbiddenPaths()
        for url in items {
            try Task.checkCancellation()
            if let reason = refusal(for: url) {
                failed.append(Refusal(url: url, reason: reason))
                continue
            }
            let location = realLocation(of: url)
            // Looked at again in full first: nothing in a folder is overwritten if it holds something
            // Tidy never touches.
            var held: String?
            walk(location, forbidden: forbidden) { entry in
                if case .protected(let path) = entry, held == nil { held = path }
            }
            if let held {
                failed.append(Refusal(url: url, reason: Self.holdsProtected(held)))
                continue
            }
            var problems: [String] = []
            walk(location, forbidden: forbidden) { entry in
                do {
                    switch entry {
                    case .file(let path, _):
                        let before = written
                        written += try Self.overwrite(path) { progress(before + $0) }
                        try Self.removeEntry(path, isFolder: false)
                    case .link(let path):
                        try Self.removeEntry(path, isFolder: false)
                    case .folder(let path):
                        try Self.removeEntry(path, isFolder: true)
                    case .protected(let path):
                        problems.append("\(path) appeared while shredding and was left alone: Tidy never touches it.")
                    }
                } catch let failure as Failure {
                    problems.append(failure.reason)
                } catch {
                    problems.append(error.localizedDescription)
                }
            }
            if problems.isEmpty, SecureFileOps.entryInfo(url.path) == nil {
                shredded.append(url)
            } else {
                failed.append(Refusal(url: url, reason: problems.first ?? "Not everything inside could be removed."))
            }
        }
        let result = Result(shredded: shredded, failed: failed, bytesOverwritten: written)
        try? appendLog(LogLine(date: Date(), action: "shredded", paths: shredded.map(\.path),
                               failed: failed.map { "\($0.url.path): \($0.reason)" }, bytes: written))
        return result
    }

    /// Writes random bytes over the whole file and flushes them to the disk. Returns the bytes written.
    /// Refuses files with other hard links: overwriting would erase those too.
    static func overwrite(_ path: String, progress: (Int64) -> Void = { _ in }) throws -> Int64 {
        let fd = open(path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure(reason: "\(path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var raw = stat()
        guard fstat(fd, &raw) == 0, UInt32(raw.st_mode) & 0o170000 == 0o100000 else {
            throw Failure(reason: "\(path) isn't a regular file.")
        }
        guard raw.st_nlink <= 1 else {
            throw Failure(reason: "\(path) has other hard links, and overwriting it would erase them too. Delete it the usual way instead.")
        }
        let size = Int64(raw.st_size)
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var generator = SystemRandomNumberGenerator()
        var offset: Int64 = 0
        while offset < size {
            let count = Int(min(Int64(buffer.count), size - offset))
            buffer.withUnsafeMutableBytes { bytes in
                let words = count / 8 * 8
                for index in stride(from: 0, to: words, by: 8) {
                    bytes.storeBytes(of: generator.next(), toByteOffset: index, as: UInt64.self)
                }
                for index in words..<count {
                    bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
                }
            }
            var done = 0
            while done < count {
                let result = buffer.withUnsafeBytes { pwrite(fd, $0.baseAddress! + done, count - done, off_t(offset) + off_t(done)) }
                guard result > 0 else { throw Failure(reason: "\(path): \(String(cString: strerror(errno))) (partly overwritten, not deleted)") }
                done += result
            }
            offset += Int64(count)
            progress(offset)
        }
        #if canImport(Darwin)
        // F_FULLFSYNC asks the drive itself to write out its cache, not just the system.
        if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
        #else
        fsync(fd)
        #endif
        return size
    }

    /// Renames the entry to a random name first, so its name doesn't linger in the folder, then removes it.
    static func removeEntry(_ path: String, isFolder: Bool) throws {
        let slash = path.lastIndex(of: "/") ?? path.startIndex
        let folder = slash == path.startIndex ? "" : String(path[..<slash])
        let hidden = folder + "/." + String(UInt64.random(in: .min ... .max), radix: 16)
        let target = rename(path, hidden) == 0 ? hidden : path
        let result = isFolder ? rmdir(target) : unlink(target)
        guard result == 0 else { throw Failure(reason: "\(path): \(String(cString: strerror(errno)))") }
    }

    struct LogLine: Codable {
        let date: Date
        /// "start" with what was chosen, then "shredded" with what is gone.
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
