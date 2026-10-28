import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AvailableUpdate: Identifiable, Sendable {
    public let app: InstalledApp
    public let currentVersion: String
    public let item: AppcastItem

    public var id: String { app.id }
}

/// Checks apps that update with Sparkle against their appcasts. Read-only: it never installs anything.
public struct SparkleUpdateChecker: Sendable {
    public let fetch: @Sendable (URL) async throws -> Data

    public init(fetch: @escaping @Sendable (URL) async throws -> Data) {
        self.fetch = fetch
    }

    #if os(macOS)
    public init() {
        self.init { url in
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            let (data, _) = try await URLSession.shared.data(for: request)
            return data
        }
    }
    #endif

    /// The running system's version, such as "14.5.0", for `check(_:osVersion:)`.
    public static var currentOSVersion: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    /// Apps whose feed offers a newer version than the one installed. Feeds that fail are skipped.
    public func check(_ apps: [InstalledApp], osVersion: String) async -> [AvailableUpdate] {
        await withTaskGroup(of: AvailableUpdate?.self) { group in
            for app in apps {
                guard let feed = app.sparkleFeedURL, feed.scheme == "https" || feed.scheme == "http" else { continue }
                group.addTask {
                    guard let data = try? await fetch(feed),
                          let latest = AppcastParser.latest(in: AppcastParser.parse(data), osVersion: osVersion)
                    else { return nil }
                    let current = app.buildVersion ?? app.version ?? "0"
                    guard VersionComparator.isNewer(latest.version, than: current) else { return nil }
                    return AvailableUpdate(app: app, currentVersion: app.version ?? current, item: latest)
                }
            }
            var updates: [AvailableUpdate] = []
            for await update in group {
                if let update { updates.append(update) }
            }
            return updates.sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
        }
    }
}

/// Homebrew casks with newer versions, from `brew outdated --cask --json=v2`.
public struct OutdatedCask: Identifiable, Hashable, Sendable {
    public let token: String
    public let installedVersion: String
    public let currentVersion: String

    public var id: String { token }

    public static func parse(_ json: Data) -> [OutdatedCask] {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]]
        else { return [] }
        return casks.compactMap { cask in
            guard let token = cask["name"] as? String, let current = cask["current_version"] as? String else { return nil }
            let installed = (cask["installed_versions"] as? [String])?.last ?? "?"
            return OutdatedCask(token: token, installedVersion: installed, currentVersion: current)
        }
        .sorted { $0.token < $1.token }
    }
}

public enum Homebrew {
    /// Where brew lives on Apple silicon and Intel Macs.
    public static var executable: URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public struct Failure: Error, LocalizedError {
        public let status: Int32
        public var errorDescription: String? { "Homebrew stopped with exit code \(status). Try the same command in Terminal to see why." }
    }

    /// Runs brew with arguments and returns its standard output.
    /// With `requireSuccess`, a non-zero exit status throws.
    public static func run(_ arguments: [String], requireSuccess: Bool = true) async throws -> Data {
        guard let brew = executable else { throw CocoaError(.fileNoSuchFile) }
        let process = Process()
        process.executableURL = brew
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        return try await withCheckedThrowingContinuation { continuation in
            // Read until brew closes its output, so a large reply can't fill the pipe and stall it.
            DispatchQueue.global().async {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if requireSuccess, process.terminationStatus != 0 {
                    continuation.resume(throwing: Failure(status: process.terminationStatus))
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }

    public static func outdatedCasks() async throws -> [OutdatedCask] {
        OutdatedCask.parse(try await run(["outdated", "--cask", "--greedy", "--json=v2"], requireSuccess: false))
    }
}
