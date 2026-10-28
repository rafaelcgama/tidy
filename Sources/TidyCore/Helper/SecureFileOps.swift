import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// File operations for code running as root. No symlink anywhere in a path is followed, so a folder
/// swapped for a link between a check and a move can't send the move somewhere else.
public enum SecureFileOps {
    /// What lstat (or stat) says about one directory entry.
    public struct EntryInfo: Sendable, Equatable {
        public let owner: UInt32
        public let permissions: UInt32
        public let isDirectory: Bool
        public let isSymlink: Bool
        /// BSD file flags; always 0 on Linux.
        public let flags: UInt32

        public var isSticky: Bool { permissions & 0o1000 != 0 }
        /// Group or others may write it, and no sticky bit stops them renaming what's inside.
        public var othersCanReplaceEntries: Bool { permissions & 0o022 != 0 && !isSticky }
        /// Locked, or protected by System Integrity Protection: moving fails even for root.
        public var isProtectedByFlags: Bool { flags & Self.protectiveFlags != 0 }

        // UF_IMMUTABLE, SF_IMMUTABLE, SF_RESTRICTED (SIP) and SF_NOUNLINK.
        static let protectiveFlags: UInt32 = 0x0000_0002 | 0x0002_0000 | 0x0008_0000 | 0x0010_0000
    }

    public struct Failure: Error, LocalizedError, Equatable {
        public let path: String
        public let code: Int32
        public let message: String?

        public var errorDescription: String? {
            "\(path): \(message ?? String(cString: strerror(code)))"
        }
    }

    /// Moves files for QuarantineStore without following symlinks.
    public static let mover: QuarantineStore.Mover = { source, destination in
        try move(source.path, to: destination.path)
    }

    /// The entry itself (lstat), or with `followingLinks` what a symlink points to. Nil when nothing is there.
    public static func entryInfo(_ path: String, followingLinks: Bool = false) -> EntryInfo? {
        var raw = stat()
        guard (followingLinks ? stat(path, &raw) : lstat(path, &raw)) == 0 else { return nil }
        return EntryInfo(raw)
    }

    /// The path with every symlink resolved (realpath(3)); nil if it doesn't exist.
    public static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Opens a directory by walking down from / one component at a time, refusing any symlink.
    /// The caller closes the descriptor.
    public static func openDirectory(_ path: String) throws -> Int32 {
        let components = try parts(of: path)
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw failure("/") }
        for component in components {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            close(fd)
            guard next >= 0 else { throw Failure(path: path, code: code, message: nil) }
            fd = next
        }
        return fd
    }

    /// Renames `source` to `destination` (absolute paths, one volume) without following a symlink
    /// on the way to either, and without replacing anything already at `destination`.
    public static func move(_ source: String, to destination: String) throws {
        let from = try split(source)
        let to = try split(destination)
        let fromFD = try openDirectory(from.folder)
        defer { close(fromFD) }
        let toFD = try openDirectory(to.folder)
        defer { close(toFD) }
        #if canImport(Darwin)
        // RENAME_EXCL: fail rather than replace an existing entry.
        let result = renameatx_np(fromFD, from.name, toFD, to.name, 0x0000_0004)
        #else
        var existing = stat()
        guard fstatat(toFD, to.name, &existing, AT_SYMLINK_NOFOLLOW) != 0 else {
            throw Failure(path: destination, code: EEXIST, message: nil)
        }
        let result = renameat(fromFD, from.name, toFD, to.name)
        #endif
        guard result == 0 else { throw failure(source) }
    }

    /// Makes sure `path` is a folder nobody but `owner` (or root) can change, creating what's missing.
    /// Every folder on the way must be a real folder, not a symlink, that others can't rename entries in.
    public static func prepareTrustedFolder(_ path: String, owner: UInt32 = 0) throws {
        let components = try parts(of: path)
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw failure("/") }
        defer { close(fd) }
        try checkTrusted(fd, path: "/", owner: owner)
        var walked = ""
        for component in components {
            walked += "/" + component
            if mkdirat(fd, component, 0o755) != 0, errno != EEXIST { throw failure(walked) }
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw failure(walked) }
            close(fd)
            fd = next
            try checkTrusted(fd, path: walked, owner: owner)
        }
    }

    // MARK: - Internals

    private static func checkTrusted(_ fd: Int32, path: String, owner: UInt32) throws {
        var raw = stat()
        guard fstat(fd, &raw) == 0 else { throw failure(path) }
        let info = EntryInfo(raw)
        guard info.owner == owner || info.owner == 0 else {
            throw Failure(path: path, code: EPERM, message: "belongs to another user, so Tidy won't keep quarantined items there")
        }
        guard !info.othersCanReplaceEntries else {
            throw Failure(path: path, code: EPERM, message: "other users can change it, so Tidy won't keep quarantined items there")
        }
    }

    /// The components of an absolute path. Relative paths, and "." or ".." anywhere, are refused.
    static func parts(of path: String) throws -> [String] {
        guard path.hasPrefix("/") else { throw Failure(path: path, code: EINVAL, message: "not a full path") }
        let components = path.split(separator: "/").map(String.init)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw Failure(path: path, code: EINVAL, message: "contains . or ..")
        }
        return components
    }

    static func split(_ path: String) throws -> (folder: String, name: String) {
        let components = try parts(of: path)
        guard let name = components.last else { throw Failure(path: path, code: EINVAL, message: "has no name") }
        return ("/" + components.dropLast().joined(separator: "/"), name)
    }

    private static func failure(_ path: String) -> Failure {
        Failure(path: path, code: errno, message: nil)
    }
}

extension SecureFileOps.EntryInfo {
    init(_ raw: stat) {
        let mode = UInt32(raw.st_mode)
        let type = mode & 0o170000
        #if canImport(Darwin)
        let flags = UInt32(raw.st_flags)
        #else
        let flags: UInt32 = 0
        #endif
        self.init(owner: UInt32(raw.st_uid), permissions: mode & 0o7777,
                  isDirectory: type == 0o040000, isSymlink: type == 0o120000, flags: flags)
    }
}
