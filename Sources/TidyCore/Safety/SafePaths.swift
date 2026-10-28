import Foundation

/// Allowlist of paths Tidy may clean, plus paths it must never touch.
public struct SafePaths: Sendable {
    public let allowedRoots: [URL]
    public let forbiddenRoots: [URL]

    public init(allowedRoots: [URL], forbiddenRoots: [URL] = SafePaths.defaultForbidden) {
        self.allowedRoots = allowedRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        self.forbiddenRoots = forbiddenRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    public static var defaultForbidden: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/System"),
            home.appendingPathComponent("Library/Keychains"),
            home.appendingPathComponent("Library/Mail"),
            home.appendingPathComponent("Pictures/Photos Library.photoslibrary"),
        ]
    }

    /// Allows what either allowlist allows, and forbids what either forbids.
    public func merging(_ other: SafePaths) -> SafePaths {
        SafePaths(allowedRoots: allowedRoots + other.allowedRoots, forbiddenRoots: forbiddenRoots + other.forbiddenRoots)
    }

    /// True only if the path is inside an allowed root and outside every forbidden root.
    public func permits(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        func isInside(_ root: URL) -> Bool {
            path == root.path || path.hasPrefix(root.path + "/")
        }
        if forbiddenRoots.contains(where: isInside) { return false }
        return allowedRoots.contains(where: isInside)
    }
}
