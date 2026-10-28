import Foundation

/// What installer packages put on the Mac, read from the receipts macOS keeps for every .pkg it
/// installs (`pkgutil`). An app installed from a package can spread files outside its bundle, such as
/// audio drivers, plug-ins and command-line tools, and its receipt lists every one.
public struct InstallerPackages: Sendable {
    /// A package's receipt: where it installed, and every path it installed there.
    public struct Receipt: Sendable, Equatable {
        public let id: String
        /// The absolute install location, such as "/".
        public let root: String
        /// Relative to `root`, folders included.
        public let paths: [String]
    }

    /// Runs pkgutil with these arguments and returns what it printed; nil when it can't run or fails.
    let pkgutil: @Sendable ([String]) -> String?
    /// Where macOS keeps the receipts.
    public let receiptsFolder: URL
    /// Entries directly inside these folders may be offered: the folders Tidy's helper works in.
    public let folders: [HelperPolicy.Folder]

    public init(pkgutil: @escaping @Sendable ([String]) -> String? = InstallerPackages.runPkgutil,
                receiptsFolder: URL = URL(fileURLWithPath: "/private/var/db/receipts"),
                folders: [HelperPolicy.Folder] = HelperPolicy.systemFolders) {
        self.pkgutil = pkgutil
        self.receiptsFolder = receiptsFolder
        self.folders = folders
    }

    public static let system = InstallerPackages()

    public static let runPkgutil: @Sendable ([String]) -> String? = { arguments in
        guard let result = try? Subprocess.run(URL(fileURLWithPath: "/usr/sbin/pkgutil"), arguments),
              result.status == 0 else { return nil }
        return result.output
    }

    /// Every folder what it finds can come from; the allowlist for removing it.
    public var searchedFolders: [URL] {
        folders.map { URL(fileURLWithPath: $0.path) } + [receiptsFolder]
    }

    /// The ids of the packages that installed this path.
    public func packages(installing path: String) -> [String] {
        guard let output = pkgutil(["--file-info", path]) else { return [] }
        return Self.values(of: "pkgid", in: output).filter { !$0.isEmpty }
    }

    public func receipt(_ id: String) -> Receipt? {
        guard let info = pkgutil(["--pkg-info", id]), let files = pkgutil(["--files", id]) else { return nil }
        let volume = Self.values(of: "volume", in: info).first ?? "/"
        let location = Self.values(of: "location", in: info).first ?? ""
        let paths = files.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return Receipt(id: id, root: Self.join(volume, location), paths: paths)
    }

    /// What the app's packages installed outside the app, as entries directly inside `folders`, plus
    /// the packages' receipts. An entry that another package installed too, such as a vendor folder
    /// several apps share, is left alone. Other apps from the same package are listed, not selected.
    public func leftovers(of appURL: URL) -> [ScanItem] {
        let ids = packages(installing: appURL.path)
        guard !ids.isEmpty else { return [] }
        let mine = Set(ids)
        let appPath = appURL.path
        var entries = Set<String>()
        for receipt in ids.compactMap(receipt) {
            for relative in receipt.paths {
                let path = Self.join(receipt.root, relative)
                guard path != appPath, !path.hasPrefix(appPath + "/"), let entry = entry(containing: path) else { continue }
                entries.insert(entry)
            }
        }
        var items: [ScanItem] = []
        for entry in entries.sorted() {
            guard (try? FileManager.default.attributesOfItem(atPath: entry)) != nil,
                  Set(packages(installing: entry)).isSubset(of: mine) else { continue }
            let url = URL(fileURLWithPath: entry)
            let isApp = url.pathExtension == "app"
            items.append(ScanItem(url: url, size: DiskUsage.size(of: url),
                                  category: isApp ? "Apps from the same installer" : "Installer files", isSelected: !isApp))
        }
        // The receipts themselves, so macOS stops listing the packages as installed.
        for id in ids.sorted() {
            for kind in ["bom", "plist"] {
                let path = receiptsFolder.appendingPathComponent(id + "." + kind).path
                guard entry(containing: path) == path, FileManager.default.fileExists(atPath: path) else { continue }
                let url = URL(fileURLWithPath: path)
                items.append(ScanItem(url: url, size: DiskUsage.size(of: url), category: "Installer receipts", isSelected: true))
            }
        }
        return items
    }

    /// The entry directly inside the most specific folder that holds `path`, when its name is allowed there.
    func entry(containing path: String) -> String? {
        guard let folder = folders.filter({ path.hasPrefix($0.path + "/") }).max(by: { $0.path.count < $1.path.count }),
              let name = path.dropFirst(folder.path.count + 1).split(separator: "/").first.map(String.init),
              folder.accepts(name: name)
        else { return nil }
        return folder.path + "/" + name
    }

    /// The values of pkgutil's "key: value" lines.
    static func values(of key: String, in output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            guard let colon = line.firstIndex(of: ":"), line[..<colon] == key else { return nil }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
    }

    /// An absolute path from an install root and a receipt's relative path.
    static func join(_ root: String, _ relative: String) -> String {
        let parts = (root.split(separator: "/") + relative.split(separator: "/")).filter { $0 != "." }
        return "/" + parts.joined(separator: "/")
    }
}
