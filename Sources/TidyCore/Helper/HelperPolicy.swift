import Foundation

/// What Tidy's privileged helper may move: entries directly inside a few system folders, under
/// each folder's own name rules. Anything else is refused, whatever the app asks for.
public struct HelperPolicy: Sendable {
    public struct Folder: Sendable, Hashable {
        /// Canonical path, with no symlink in it (/private/var/log, not /var/log).
        public let path: String
        /// Accepted name endings, lowercased; empty accepts any name.
        public let suffixes: [String]
        /// Refused name beginnings, lowercased.
        public let refusedPrefixes: [String]
        /// Refused names, lowercased.
        public let refusedNames: Set<String>

        public init(_ path: String, suffixes: [String] = [], refusedPrefixes: [String] = [], refusedNames: Set<String> = []) {
            self.path = path
            self.suffixes = suffixes.map { $0.lowercased() }
            self.refusedPrefixes = refusedPrefixes.map { $0.lowercased() }
            self.refusedNames = Set(refusedNames.map { $0.lowercased() })
        }

        /// Whether an entry with this name may be moved out of this folder. Hidden entries never are.
        public func accepts(name: String) -> Bool {
            guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("\0") else { return false }
            let lower = name.lowercased()
            if refusedNames.contains(lower) || refusedPrefixes.contains(where: { lower.hasPrefix($0) }) { return false }
            return suffixes.isEmpty || suffixes.contains(where: { lower.hasSuffix($0) })
        }
    }

    public enum Refusal: Error, Equatable, LocalizedError {
        case notAbsolute
        case notAllowedFolder
        case nameNotAllowed
        case folderNotInPlace
        case missing
        case protectedByMacOS
        case protectedItem

        public var errorDescription: String? {
            switch self {
            case .notAbsolute: return "Not a full path."
            case .notAllowedFolder: return "Tidy's helper only works in system cache, log, launch, preference, app and plug-in folders, and with installer receipts."
            case .nameNotAllowed: return "Tidy's helper doesn't move items with this name from this folder."
            case .folderNotInPlace: return "Its folder is missing or a symlink is in the way."
            case .missing: return "It's no longer there."
            case .protectedByMacOS: return "macOS protects it."
            case .protectedItem: return "Tidy doesn't remove itself."
            }
        }
    }

    /// A checked path: one entry directly inside one of the policy's folders.
    public struct Target: Sendable, Equatable {
        public let folder: Folder
        public let name: String
        public var path: String { folder.path + "/" + name }
    }

    public let folders: [Folder]
    /// Lowercased paths that are never moved, such as the app bundle the helper ships in.
    public let protectedPaths: Set<String>

    public init(folders: [Folder] = HelperPolicy.systemFolders, protectedPaths: Set<String> = []) {
        self.folders = folders
        self.protectedPaths = Set(protectedPaths.map { $0.lowercased() })
    }

    public static let standard = HelperPolicy()

    public static let systemFolders: [Folder] = [
        Folder("/Library/Caches"),
        // Crash reports are offered one by one, so their folder stays.
        Folder("/Library/Logs", refusedNames: ["DiagnosticReports"]),
        Folder("/Library/Logs/DiagnosticReports"),
        // Rotated archives only: live logs stay where their daemons write them.
        Folder("/private/var/log", suffixes: [".gz", ".bz2"]),
        Folder("/Library/LaunchAgents", suffixes: [".plist"], refusedPrefixes: ["com.apple."]),
        Folder("/Library/LaunchDaemons", suffixes: [".plist"], refusedPrefixes: ["com.apple."]),
        Folder("/Library/PrivilegedHelperTools", refusedPrefixes: ["com.apple."]),
        // Application Support/Tidy holds the helper's own quarantine.
        Folder("/Library/Application Support", refusedPrefixes: ["com.apple.", "apple"], refusedNames: ["Tidy"]),
        Folder("/Library/Preferences", suffixes: [".plist"], refusedPrefixes: ["com.apple."]),
        Folder("/Applications", suffixes: [".app"]),
        Folder("/Applications/Utilities", suffixes: [".app"]),
        // Where installer packages put plug-ins and tools outside an app. Tidy offers what's here only
        // when the app's own package receipt lists it (InstallerPackages).
        Folder("/Library/Audio/Plug-Ins/HAL", suffixes: [".driver", ".plugin"]),
        Folder("/Library/Audio/Plug-Ins/Components", suffixes: [".component"]),
        Folder("/Library/Internet Plug-Ins", suffixes: [".plugin", ".webplugin"]),
        Folder("/Library/PreferencePanes", suffixes: [".prefpane"]),
        Folder("/Library/QuickLook", suffixes: [".qlgenerator"]),
        Folder("/Library/Spotlight", suffixes: [".mdimporter"]),
        Folder("/usr/local/bin"),
        // The receipts themselves, so macOS stops listing a removed package as installed.
        Folder("/private/var/db/receipts", suffixes: [".bom", ".plist"], refusedPrefixes: ["com.apple."]),
    ]

    /// The rule for an entry's folder, judged by path alone; nil where the helper never works.
    /// Scanners use it to offer only what the helper would accept.
    public func folder(for url: URL) -> Folder? {
        let parent = Self.canonical(url.deletingLastPathComponent().path)
        return folders.first { $0.path == parent }
    }

    /// Whether the helper would accept this path, judging by its folder and name only.
    public func accepts(_ url: URL) -> Bool {
        folder(for: url)?.accepts(name: url.lastPathComponent) == true
    }

    /// Checks a path to put something back at: an allowed folder that is really there, with no
    /// symlink on the way, and a name allowed in it.
    public func destination(_ path: String) throws -> Target {
        guard (try? SecureFileOps.parts(of: path)) != nil else { throw Refusal.notAbsolute }
        let url = URL(fileURLWithPath: path)
        guard let folder = folder(for: url) else { throw Refusal.notAllowedFolder }
        let name = url.lastPathComponent
        guard folder.accepts(name: name) else { throw Refusal.nameNotAllowed }
        guard SecureFileOps.realPath(folder.path) == folder.path else { throw Refusal.folderNotInPlace }
        let target = Target(folder: folder, name: name)
        guard !protectedPaths.contains(target.path.lowercased()) else { throw Refusal.protectedItem }
        return target
    }

    /// Checks a path the app asks to move: everything `destination` checks, and the entry is there
    /// and not locked or protected by macOS.
    public func source(_ path: String) throws -> Target {
        let target = try destination(path)
        guard let info = SecureFileOps.entryInfo(target.path) else { throw Refusal.missing }
        guard !info.isProtectedByFlags else { throw Refusal.protectedByMacOS }
        return target
    }

    /// On macOS /var, /tmp and /etc are symlinks into /private.
    static func canonical(_ path: String) -> String {
        #if os(macOS)
        for link in ["/var", "/tmp", "/etc"] where path == link || path.hasPrefix(link + "/") {
            return "/private" + path
        }
        #endif
        return path
    }
}
