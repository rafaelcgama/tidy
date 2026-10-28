import Foundation

/// Folders that searches of the user's own files leave out: app and system data, such as ~/Library,
/// and the dependencies and build output inside projects. Identical copies are normal there (every
/// project has its own node_modules), and removing one breaks the app or project it belongs to.
/// A folder the user chooses is searched in full, even when it's one of these.
public struct SkippedFolders: Sendable {
    /// App and system data.
    public let places: [URL]
    /// Folders inside `places` that hold the user's own files, so they're searched anyway.
    public let exceptions: [URL]

    public init(places: [URL], exceptions: [URL] = []) {
        self.places = places
        self.exceptions = exceptions
    }

    /// ~/Library (except iCloud Drive and other cloud storage, which live in it) and the system's folders.
    public init(home: URL) {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let system = ["/Library", "/System", "/Applications", "/usr", "/bin", "/sbin", "/opt", "/private", "/cores"]
        self.init(places: [library] + system.map { URL(fileURLWithPath: $0, isDirectory: true) },
                  exceptions: [library.appendingPathComponent("Mobile Documents"), library.appendingPathComponent("CloudStorage")])
    }

    public static var standard: SkippedFolders {
        SkippedFolders(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Dependencies and build output: a folder name, and the files next to it that show it's part of
    /// a project (none when the name alone is clear enough).
    static let projectFolders: [String: [String]] = [
        "node_modules": [],
        "bower_components": [],
        "DerivedData": [],
        "site-packages": [],
        "__pycache__": [],
        "Pods": ["Podfile"],
        "Carthage": ["Cartfile"],
        "target": ["Cargo.toml", "pom.xml"],
        "build": ["package.json", "build.gradle", "build.gradle.kts", "CMakeLists.txt", "pubspec.yaml", "pyproject.toml", "setup.py"],
        "dist": ["package.json", "pyproject.toml", "setup.py"],
        "vendor": ["Gemfile", "composer.json", "go.mod"],
    ]

    /// Whether a folder is a project's dependencies or build output.
    static func isProjectFolder(_ url: URL) -> Bool {
        guard let markers = projectFolders[url.lastPathComponent] else { return false }
        let project = url.deletingLastPathComponent()
        return markers.isEmpty || markers.contains { FileManager.default.fileExists(atPath: project.appendingPathComponent($0).path) }
    }

    /// Whether the folder is, or is inside, a project's dependencies or build output.
    static func isInsideProjectFolder(_ url: URL) -> Bool {
        var folder = url
        for _ in url.pathComponents.dropFirst() {
            if isProjectFolder(folder) { return true }
            folder = folder.deletingLastPathComponent()
        }
        return false
    }

    /// The rules for a search of one folder. Places the folder is in are searched: the user chose them.
    func search(of root: URL) -> Search {
        let roots = Self.paths(of: root)
        let left = places.filter { place in
            !Self.paths(of: place).contains { placePath in roots.contains { Self.relative($0, to: [placePath]) != nil } }
        }
        return Search(roots: roots,
                      places: left.compactMap { Self.relativePath(of: $0, in: roots) },
                      exceptions: exceptions.compactMap { Self.relativePath(of: $0, in: roots) },
                      skipsProjectFolders: !Self.isInsideProjectFolder(root))
    }

    /// What one search leaves out, with paths relative to the folder searched.
    struct Search {
        /// The folder's path as given and, when different, as resolved.
        let roots: [String]
        let places: [String]
        let exceptions: [String]
        let skipsProjectFolders: Bool

        func skips(_ url: URL, isDirectory: Bool) -> Bool {
            if isDirectory, skipsProjectFolders, SkippedFolders.isProjectFolder(url) { return true }
            guard !places.isEmpty, let path = SkippedFolders.relative(url.path, to: roots),
                  places.contains(where: { SkippedFolders.isInside(path, $0) })
            else { return false }
            // Searched anyway: the exceptions, and the folders on the way to them.
            return !exceptions.contains { SkippedFolders.isInside(path, $0) || (isDirectory && SkippedFolders.isInside($0, path)) }
        }
    }

    // MARK: - Paths

    /// A path as given and, when different, with symlinks resolved: on macOS /var is /private/var,
    /// and a folder's contents may be listed under either.
    private static func paths(of url: URL) -> [String] {
        let path = url.path
        guard let real = SecureFileOps.realPath(path), real != path else { return [path] }
        return [path, real]
    }

    /// `path` relative to a folder known by any of `roots`, or nil if it's not inside it.
    static func relative(_ path: String, to roots: [String]) -> String? {
        for root in roots {
            if path == root { return "" }
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        return nil
    }

    /// A folder's path relative to the folder searched, if it's below it.
    private static func relativePath(of folder: URL, in roots: [String]) -> String? {
        paths(of: folder).lazy.compactMap { relative($0, to: roots) }.first { !$0.isEmpty }
    }

    /// Whether a relative path is the folder or inside it.
    static func isInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder + "/")
    }
}
