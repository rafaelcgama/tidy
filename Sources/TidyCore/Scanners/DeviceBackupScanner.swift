import Foundation

/// iPhone and iPad backups made by Finder or iTunes: often many gigabytes each, and often of devices
/// you no longer have. A backup may be the only copy of what was on a device, so none is preselected.
public struct DeviceBackupScanner: CleaningScanner {
    public let name = "Device backups"
    public let folder: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        folder = home.appendingPathComponent("Library/Application Support/MobileSync/Backup")
    }

    public var safePaths: SafePaths {
        SafePaths(allowedRoots: [folder])
    }

    public func scan(progress: @Sendable (ScanProgress) -> Void) async throws -> [ScanItem] {
        // macOS shows this folder only to apps with Full Disk Access.
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let backups = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                                                         options: [.skipsHiddenFiles])
        else { return [] }
        var items: [ScanItem] = []
        for (index, backup) in backups.enumerated() {
            try Task.checkCancellation()
            guard let values = try? backup.resourceValues(forKeys: keys), values.isDirectory == true, values.isSymbolicLink != true
            else { continue }
            progress(ScanProgress(completed: index, total: backups.count, currentPath: backup.path))
            let usage = DiskUsage.usage(of: backup)
            guard usage.size > 0 else { continue }
            let info = Self.info(of: backup)
            items.append(ScanItem(url: backup, size: usage.size, category: "iPhone and iPad backups",
                                  lastModified: info.date ?? usage.lastModified, label: Self.label(device: info.device, date: info.date)))
        }
        progress(ScanProgress(completed: backups.count, total: backups.count, currentPath: nil))
        return items.sorted { $0.size > $1.size }
    }

    /// The device's name and when it was backed up, from the backup's Info.plist.
    static func info(of backup: URL) -> (device: String?, date: Date?) {
        guard let data = try? Data(contentsOf: backup.appendingPathComponent("Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return (nil, nil) }
        return ((plist["Device Name"] as? String) ?? (plist["Display Name"] as? String), plist["Last Backup Date"] as? Date)
    }

    /// "Work iPhone, backed up 3 Mar 2025". Nil when the backup doesn't say which device it is, so its folder name shows.
    static func label(device: String?, date: Date?) -> String? {
        guard let device, !device.isEmpty else { return nil }
        guard let date else { return device }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "\(device), backed up \(formatter.string(from: date))"
    }
}
