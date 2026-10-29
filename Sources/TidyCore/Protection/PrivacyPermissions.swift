import Foundation

/// The apps macOS lets use the camera, microphone or screen, read what you type, control the Mac or read
/// every file: what spyware needs. macOS keeps these in its privacy (TCC) databases, which only apps with
/// Full Disk Access can read.
public struct PrivacyPermissions: Sendable {
    public struct Kind: Sendable, Hashable {
        public let service: String
        public let title: String
        /// Its page in System Settings › Privacy & Security, where an app's access is turned off.
        public let settingsURL: URL
    }

    public struct Grant: Identifiable, Hashable, Sendable {
        public let kind: Kind
        /// The app's name, or the program's.
        public let name: String
        /// A bundle id, or a program's path.
        public let client: String

        public var id: String { kind.service + " " + client }
    }

    public struct Report: Sendable {
        /// Kind by kind, as in `kinds`, and by name within each.
        public let grants: [Grant]
        /// Databases that couldn't be read, so some grants may be missing.
        public let unreadable: [URL]

        public var isComplete: Bool { unreadable.isEmpty }
    }

    public static let kinds: [Kind] = [
        kind("kTCCServiceCamera", "Camera", "Privacy_Camera"),
        kind("kTCCServiceMicrophone", "Microphone", "Privacy_Microphone"),
        kind("kTCCServiceScreenCapture", "Screen recording", "Privacy_ScreenCapture"),
        kind("kTCCServiceListenEvent", "Input Monitoring: what you type", "Privacy_ListenEvent"),
        kind("kTCCServiceAccessibility", "Accessibility: control your Mac", "Privacy_Accessibility"),
        kind("kTCCServiceSystemPolicyAllFiles", "Full Disk Access: every file", "Privacy_AllFiles"),
    ]

    public static var fullDiskAccessSettings: URL { kinds[kinds.count - 1].settingsURL }

    private static func kind(_ service: String, _ title: String, _ anchor: String) -> Kind {
        Kind(service: service, title: title, settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }

    /// Yours (camera and microphone) and the system's (screen, typing, control and files).
    public let databases: [URL]
    /// Runs a query on a database and returns sqlite3's JSON output; nil when the database can't be read.
    let query: @Sendable (URL, String) -> String?
    /// App names by bundle id.
    let appNames: @Sendable () -> [String: String]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                query: @escaping @Sendable (URL, String) -> String? = PrivacyPermissions.runSQLite,
                appNames: @escaping @Sendable () -> [String: String] = PrivacyPermissions.installedAppNames) {
        databases = [home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db"),
                     URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")]
        self.query = query
        self.appNames = appNames
    }

    public static let runSQLite: @Sendable (URL, String) -> String? = { database, sql in
        guard let result = try? Subprocess.run(URL(fileURLWithPath: "/usr/bin/sqlite3"), ["-readonly", "-json", database.path, sql]),
              result.status == 0
        else { return nil }
        return result.output
    }

    public static let installedAppNames: @Sendable () -> [String: String] = {
        Dictionary(AppInventory.apps(in: AppInventory.defaultFolders() + AppInventory.systemFolders).map { ($0.bundleID, $0.name) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// Apps allowed (auth_value 2) one of the kinds. A client_type of 0 means a bundle id, 1 a program's path.
    static var sql: String {
        "SELECT service, client, client_type FROM access WHERE auth_value = 2 AND service IN ("
            + kinds.map { "'\($0.service)'" }.joined(separator: ", ") + ")"
    }

    public func read() -> Report {
        struct Row: Decodable {
            let service: String
            let client: String
            let clientType: Int

            enum CodingKeys: String, CodingKey {
                case service, client
                case clientType = "client_type"
            }
        }
        var rows: [Row] = []
        var unreadable: [URL] = []
        for database in databases {
            guard let output = query(database, Self.sql) else {
                unreadable.append(database)
                continue
            }
            // With no rows, sqlite3 prints nothing.
            if output.allSatisfy(\.isWhitespace) { continue }
            guard let found = try? JSONDecoder().decode([Row].self, from: Data(output.utf8)) else {
                unreadable.append(database)
                continue
            }
            rows += found
        }
        let names = rows.isEmpty ? [:] : appNames()
        var seen: Set<String> = []
        let grants = Self.kinds.flatMap { kind in
            rows.filter { $0.service == kind.service }
                .map { Grant(kind: kind, name: $0.clientType == 1 ? Self.programName($0.client) : names[$0.client] ?? $0.client, client: $0.client) }
                .filter { seen.insert($0.id).inserted }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return Report(grants: grants, unreadable: unreadable)
    }

    /// The app a program is in, such as "zoom.us" for /Applications/zoom.us.app/…/CptHost, or else the program's own name.
    static func programName(_ path: String) -> String {
        let parts = path.split(separator: "/")
        if let app = parts.first(where: { $0.hasSuffix(".app") }) { return String(app.dropLast(4)) }
        return parts.last.map(String.init) ?? path
    }
}
