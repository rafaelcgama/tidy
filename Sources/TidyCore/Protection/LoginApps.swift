import Foundation

/// An app that opens when you log in (System Settings › General › Login Items › Open at Login).
public struct LoginApp: Codable, Hashable, Identifiable, Sendable {
    public let name: String
    public let path: String
    /// Opens with its windows hidden.
    public let hidden: Bool

    public var id: String { path }

    public init(name: String, path: String, hidden: Bool) {
        self.name = name
        self.path = path
        self.hidden = hidden
    }
}

/// The apps that open at login, read and changed through System Events (macOS asks once whether
/// Tidy may). Turning one off takes it off the list, and Tidy remembers it so it can go back on.
public struct LoginApps: Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        /// macOS didn't let Tidy ask System Events (System Settings › Privacy & Security › Automation).
        case notAllowed
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notAllowed: return "macOS didn't allow Tidy to ask System Events for the list."
            case .failed(let message): return message
            }
        }
    }

    /// Where Tidy remembers the apps it turned off.
    public let storeURL: URL
    let osascript: URL

    public init(storeURL: URL = LoginApps.defaultStoreURL, osascript: URL = URL(fileURLWithPath: "/usr/bin/osascript")) {
        self.storeURL = storeURL
        self.osascript = osascript
    }

    public static var defaultStoreURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tidy/login-apps-turned-off.json")
    }

    /// The apps that open at login now, and the ones Tidy turned off that are still installed.
    public func list() throws -> (on: [LoginApp], off: [LoginApp]) {
        let on = Self.parse(try runScript(Self.listScript))
        let onPaths = Set(on.map(\.path))
        let off = remembered().filter { !onPaths.contains($0.path) && FileManager.default.fileExists(atPath: $0.path) }
        return (on, off)
    }

    public func turnOff(_ app: LoginApp) throws {
        _ = try runScript(Self.removeScript, arguments: [app.path])
        try remember(remembered().filter { $0.path != app.path } + [app])
    }

    public func turnOn(_ app: LoginApp) throws {
        _ = try runScript(Self.addScript, arguments: [app.path, app.hidden ? "true" : "false"])
        try remember(remembered().filter { $0.path != app.path })
    }

    // MARK: - Scripts

    /// Name, path and hidden, a line each, for every login item.
    static let listScript = """
        set output to ""
        tell application "System Events"
            repeat with loginItem in login items
                try
                    set output to output & (name of loginItem) & linefeed & (path of loginItem) & linefeed & ((hidden of loginItem) as text) & linefeed
                end try
            end repeat
        end tell
        return output
        """

    static let removeScript = """
        on run argv
            tell application "System Events" to delete (every login item whose path is (item 1 of argv))
        end run
        """

    static let addScript = """
        on run argv
            tell application "System Events" to make login item at end with properties {path:(item 1 of argv), hidden:((item 2 of argv) is "true")}
        end run
        """

    static func parse(_ output: String) -> [LoginApp] {
        var lines = output.components(separatedBy: "\n")
        while lines.last?.isEmpty == true { lines.removeLast() }
        return stride(from: 0, to: lines.count - lines.count % 3, by: 3).compactMap { index in
            let (name, path) = (lines[index], lines[index + 1])
            guard path.hasPrefix("/") else { return nil }
            return LoginApp(name: name.isEmpty ? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent : name,
                            path: path, hidden: lines[index + 2] == "true")
        }
    }

    /// Runs a script; `arguments` arrive as its `argv`, never as script text.
    func runScript(_ script: String, arguments: [String] = []) throws -> String {
        let lines = script.components(separatedBy: "\n").flatMap { ["-e", $0] }
        let result = try Subprocess.run(osascript, lines + arguments)
        guard result.status == 0 else {
            let error = AppleScriptError(result.errors)
            // Not allowed to send Apple events (-1743), or it would take a consent macOS can't ask for (-1744).
            if error.code == -1743 || error.code == -1744 { throw Failure.notAllowed }
            throw Failure.failed(error.message)
        }
        return result.output
    }

    // MARK: - Turned off

    func remembered() -> [LoginApp] {
        guard let data = try? Data(contentsOf: storeURL) else { return [] }
        return (try? JSONDecoder().decode([LoginApp].self, from: data)) ?? []
    }

    func remember(_ apps: [LoginApp]) throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(apps).write(to: storeURL, options: .atomic)
    }
}
