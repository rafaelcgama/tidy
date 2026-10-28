import Foundation

/// A launchd job: something macOS starts at login or boot and may keep running.
public struct LaunchItem: Identifiable, Hashable, Sendable {
    public enum Scope: String, Sendable {
        case userAgent = "Your login"
        case globalAgent = "Every user's login"
        case daemon = "System (runs as root)"
    }

    /// The job's plist.
    public let url: URL
    public let label: String
    /// Program, or the first of ProgramArguments.
    public let program: String?
    public let arguments: [String]
    public let runAtLoad: Bool
    public let keepAlive: Bool
    public let disabled: Bool
    public let scope: Scope

    public var id: String { url.path }

    /// The app the job comes with, from its program's path: "Dropbox" for /Applications/Dropbox.app/….
    public var appName: String? {
        guard let app = program?.split(separator: "/").first(where: { $0.hasSuffix(".app") }) else { return nil }
        return String(app.dropLast(4))
    }
}

public enum LaunchItemReader {
    public static func defaultFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [(folder: URL, scope: LaunchItem.Scope)] {
        [
            (home.appendingPathComponent("Library/LaunchAgents"), .userAgent),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .globalAgent),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .daemon),
        ]
    }

    public static func items(in folders: [(folder: URL, scope: LaunchItem.Scope)]) -> [LaunchItem] {
        var items: [LaunchItem] = []
        for (folder, scope) in folders {
            let plists = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            items += plists.filter { $0.pathExtension == "plist" }.compactMap { item(at: $0, scope: scope) }
        }
        return items.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    static func item(at url: URL, scope: LaunchItem.Scope) -> LaunchItem? {
        guard let data = try? Data(contentsOf: url),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        let arguments = plist["ProgramArguments"] as? [String] ?? []
        let keepAlive: Bool
        switch plist["KeepAlive"] {
        case let value as Bool: keepAlive = value
        case is [String: Any]: keepAlive = true
        default: keepAlive = false
        }
        return LaunchItem(url: url,
                          label: plist["Label"] as? String ?? url.deletingPathExtension().lastPathComponent,
                          program: plist["Program"] as? String ?? arguments.first,
                          arguments: arguments,
                          runAtLoad: plist["RunAtLoad"] as? Bool ?? false,
                          keepAlive: keepAlive,
                          disabled: plist["Disabled"] as? Bool ?? false,
                          scope: scope)
    }
}
