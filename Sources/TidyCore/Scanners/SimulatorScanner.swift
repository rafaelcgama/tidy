import Foundation

/// Xcode's simulators. One whose iOS (or watchOS, tvOS, visionOS) version Xcode no longer has can't run
/// anymore, so it's preselected, as `xcrun simctl delete unavailable` would delete it. The others keep
/// their apps and data, so they're listed but not preselected.
public struct SimulatorScanner: CleaningScanner {
    public let name = "Simulators"
    public let devicesFolder: URL
    /// What `simctl list devices -j` prints; nil when there's no Xcode to ask.
    let listDevices: @Sendable () -> String?

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                listDevices: @escaping @Sendable () -> String? = SimulatorScanner.askXcode) {
        devicesFolder = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
        self.listDevices = listDevices
    }

    /// Runs Xcode's simctl itself rather than through xcrun: on a Mac without developer tools, xcrun shows
    /// a dialog offering to install them.
    public static let askXcode: @Sendable () -> String? = {
        let selected = (try? Subprocess.run(URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"]))
            .flatMap { $0.status == 0 ? $0.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        for developer in [selected, "/Applications/Xcode.app/Contents/Developer"].compactMap({ $0 }) {
            let simctl = URL(fileURLWithPath: developer).appendingPathComponent("usr/bin/simctl")
            guard FileManager.default.isExecutableFile(atPath: simctl.path),
                  let result = try? Subprocess.run(simctl, ["list", "devices", "-j"]), result.status == 0
            else { continue }
            return result.output
        }
        return nil
    }

    public var safePaths: SafePaths {
        SafePaths(allowedRoots: [devicesFolder])
    }

    public func scan(progress: @Sendable (ScanProgress) -> Void) async throws -> [ScanItem] {
        // A simulator is a folder holding a device.plist; device_set.plist next to them stays.
        let folders = (try? FileManager.default.contentsOfDirectory(at: devicesFolder, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                                    options: [.skipsHiddenFiles])) ?? []
        let devices = folders
            .filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
            .compactMap { folder in Self.device(in: folder).map { (folder: folder, device: $0) } }
        // Xcode is only asked when there are simulators.
        guard !devices.isEmpty else { return [] }
        progress(ScanProgress(completed: 0, total: devices.count, currentPath: devicesFolder.path))
        let unavailable = Self.unavailable(in: listDevices())
        var items: [ScanItem] = []
        for (index, found) in devices.enumerated() {
            try Task.checkCancellation()
            progress(ScanProgress(completed: index, total: devices.count, currentPath: found.folder.path))
            let usage = DiskUsage.usage(of: found.folder)
            guard usage.size > 0 else { continue }
            let gone = unavailable.contains(found.device.udid)
            items.append(ScanItem(url: found.folder, size: usage.size, category: "Xcode simulators", isSelected: gone,
                                  lastModified: usage.lastModified, label: found.device.label + (gone ? " (no longer in Xcode)" : "")))
        }
        progress(ScanProgress(completed: devices.count, total: devices.count, currentPath: nil))
        return items.sorted { $0.size > $1.size }
    }

    struct Device: Equatable {
        let udid: String
        /// "iPhone 15, iOS 17.0"
        let label: String
    }

    /// The simulator in a folder, from its device.plist.
    static func device(in folder: URL) -> Device? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("device.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let name = plist["name"] as? String
        else { return nil }
        let runtime = (plist["runtime"] as? String).map(runtimeName)
        return Device(udid: (plist["UDID"] as? String) ?? folder.lastPathComponent, label: runtime.map { "\(name), \($0)" } ?? name)
    }

    /// "iOS 17.0" for com.apple.CoreSimulator.SimRuntime.iOS-17-0.
    static func runtimeName(_ identifier: String) -> String {
        let parts = (identifier.split(separator: ".").last ?? Substring(identifier)).split(separator: "-")
        guard let platform = parts.first, parts.count > 1 else { return identifier }
        return "\(platform) \(parts.dropFirst().joined(separator: "."))"
    }

    /// The UDIDs of simulators simctl says can't run. Empty when it didn't answer, so nothing is preselected.
    static func unavailable(in json: String?) -> Set<String> {
        struct List: Decodable {
            struct Device: Decodable {
                let udid: String
                let isAvailable: Bool?
            }
            let devices: [String: [Device]]
        }
        guard let data = json?.data(using: .utf8), let list = try? JSONDecoder().decode(List.self, from: data) else { return [] }
        return Set(list.devices.values.joined().filter { $0.isAvailable == false }.map(\.udid))
    }
}
