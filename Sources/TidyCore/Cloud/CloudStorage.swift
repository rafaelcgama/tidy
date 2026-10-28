import Foundation

/// A folder synced by a cloud service.
public struct CloudFolder: Hashable, Sendable {
    public let name: String
    public let url: URL
}

/// A file in a cloud folder. `localSize` is 0 when only the cloud has the data.
public struct CloudFile: Identifiable, Hashable, Sendable {
    public let url: URL
    public let provider: String
    public let size: Int64
    public let localSize: Int64

    public init(url: URL, provider: String, size: Int64, localSize: Int64) {
        self.url = url
        self.provider = provider
        self.size = size
        self.localSize = localSize
    }

    public var id: String { url.path }
    public var isDownloaded: Bool { localSize > 0 }
}

/// A file you have in the cloud and also keep a separate local copy of.
public struct LocalCopyOfCloudFile: Identifiable, Sendable {
    public let cloudFile: ScanItem
    public let localCopies: [ScanItem]

    public var id: UUID { cloudFile.id }
}

public enum CloudStorage {
    /// iCloud Drive, the File Provider folders in ~/Library/CloudStorage (Dropbox, Google Drive, OneDrive, Box…)
    /// and a classic ~/Dropbox, when they exist.
    public static func folders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [CloudFolder] {
        let fm = FileManager.default
        var folders: [CloudFolder] = []
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: iCloud.path) {
            folders.append(CloudFolder(name: "iCloud Drive", url: iCloud))
        }
        let providers = (try? fm.contentsOfDirectory(at: home.appendingPathComponent("Library/CloudStorage"),
                                                     includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for folder in providers.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            folders.append(CloudFolder(name: displayName(forProviderFolder: folder.lastPathComponent), url: folder))
        }
        let classicDropbox = home.appendingPathComponent("Dropbox")
        if fm.fileExists(atPath: classicDropbox.path), !folders.contains(where: { $0.name.hasPrefix("Dropbox") }) {
            folders.append(CloudFolder(name: "Dropbox", url: classicDropbox))
        }
        return folders
    }

    /// "GoogleDrive-me@example.com" → "Google Drive (me@example.com)", "OneDrive-Personal" → "OneDrive (Personal)".
    static func displayName(forProviderFolder name: String) -> String {
        let known = ["GoogleDrive": "Google Drive", "OneDrive": "OneDrive", "Dropbox": "Dropbox", "Box": "Box"]
        let parts = name.split(separator: "-", maxSplits: 1).map(String.init)
        let provider = known[parts[0]] ?? parts[0]
        guard parts.count == 2, parts[1] != parts[0] else { return provider }
        return "\(provider) (\(parts[1]))"
    }

    /// Large files in the cloud folders, largest first, whether downloaded or not. Read-only.
    public static func largeFiles(in folders: [CloudFolder], minimumSize: Int64 = 100_000_000,
                                  progress: @Sendable (ScanProgress) -> Void = { _ in }) async throws -> [CloudFile] {
        var files: [CloudFile] = []
        for folder in folders {
            for file in try FileWalker.files(under: [folder.url], minimumSize: minimumSize, progress: progress) {
                files.append(CloudFile(url: file.url, provider: folder.name, size: file.size, localSize: file.allocatedSize))
            }
        }
        return files.sorted { $0.size > $1.size }
    }

    /// Frees the local copy of a cloud file; it stays in the cloud and downloads again when opened.
    public static func removeDownload(_ url: URL) throws {
        #if os(macOS)
        try FileManager.default.evictUbiquitousItem(at: url)
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }
}

/// Finds local files that are byte-for-byte copies of files you already keep in the cloud.
/// Only the local copies can be removed; cloud folders are always off-limits.
public struct CloudCopyFinder: Sendable {
    public let localRoots: [URL]
    public let cloudFolders: [CloudFolder]
    public let minimumSize: Int64

    public init(localRoots: [URL], cloudFolders: [CloudFolder], minimumSize: Int64 = 1_000_000) {
        self.localRoots = localRoots
        self.cloudFolders = cloudFolders
        self.minimumSize = minimumSize
    }

    public var safePaths: SafePaths {
        SafePaths(allowedRoots: localRoots, forbiddenRoots: SafePaths.defaultForbidden + cloudFolders.map(\.url))
    }

    public func find(progress: @Sendable (ScanProgress) -> Void = { _ in }) async throws -> [LocalCopyOfCloudFile] {
        let groups = try await DuplicateFinder(roots: localRoots + cloudFolders.map(\.url), minimumSize: minimumSize)
            .find(progress: progress)
        let cloudRoots = SafePaths(allowedRoots: cloudFolders.map(\.url), forbiddenRoots: [])
        return groups.compactMap { group in
            let inCloud = group.files.filter { cloudRoots.permits($0.url) }
            let local = group.files.filter { !cloudRoots.permits($0.url) }
            guard let cloudFile = inCloud.first, !local.isEmpty else { return nil }
            return LocalCopyOfCloudFile(cloudFile: cloudFile, localCopies: local)
        }
    }
}
