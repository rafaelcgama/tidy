import Foundation

/// Paths as Tidy shows them, with the home folder as ~.
public enum DisplayPath {
    public static func string(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let path = url.path
        let home = home.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// The folder a file or folder is in.
    public static func folder(of url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        string(url.deletingLastPathComponent(), home: home)
    }
}
