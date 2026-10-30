import Foundation

/// The apps on the Mac, as leftovers of removed apps are judged against them (`LeftoverFinder.orphans`).
public struct KnownApps: Sendable {
    /// Every app's bundle id, lowercased.
    let ids: Set<String>
    /// The same less the helper apps vendors keep in Library folders (updaters, agents) once none of the
    /// vendor's own apps is left: what starts one of those is a leftover too.
    let idsWithoutStrandedHelpers: Set<String>
    /// Vendors ("com.vmware") with an app outside the Library folders.
    let vendors: Set<String>
    /// Lowercased names of those apps, Apple's left out, for vendors whose apps go by another id
    /// (Dropbox is com.getdropbox.dropbox, its updater com.dropbox.…).
    let names: [String]

    /// `libraries` are the Library folders leftovers are looked for in: yours and /Library.
    public init(_ apps: [InstalledApp], libraries: [URL]) {
        let folders = libraries.map { $0.standardizedFileURL.path + "/" }
        let inLibrary = { (app: InstalledApp) in folders.contains { app.url.standardizedFileURL.path.hasPrefix($0) } }
        let main = apps.filter { !inLibrary($0) }
        let vendors = Set(main.compactMap { Self.vendor(of: $0.bundleID.lowercased()) })
        let names = main.filter { !$0.bundleID.hasPrefix("com.apple.") }
            .flatMap { [$0.name.lowercased(), $0.url.deletingPathExtension().lastPathComponent.lowercased()] }
        self.vendors = vendors
        self.names = names
        // Each app's id with the ids of what it carries inside.
        let owned = apps.map { app in
            (app: app, ids: ([app.bundleID] + (app.bundleID.hasPrefix("com.apple.") ? [] : Self.embeddedIDs(in: app.url))).map { $0.lowercased() })
        }
        ids = Set(owned.flatMap(\.ids))
        idsWithoutStrandedHelpers = Set(owned.filter { app, _ in
            !inLibrary(app) || Self.vendor(of: app.bundleID.lowercased()).map { Self.isPresent($0, vendors: vendors, names: names) } == true
        }.flatMap(\.ids))
    }

    /// Where apps carry bundles of their own, each with its own id, container and settings.
    static let embeddedFolders = ["PlugIns", "Extensions", "XPCServices", "Helpers", "Library/LoginItems", "Library/SystemExtensions"]

    /// The ids of the extensions, login items, helpers and services inside an app (1Password's Safari
    /// extension is com.1password.safari, not com.1password.1password.…).
    static func embeddedIDs(in app: URL) -> [String] {
        let contents = app.appendingPathComponent("Contents")
        return embeddedFolders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(at: contents.appendingPathComponent(folder), includingPropertiesForKeys: nil)) ?? [])
                .compactMap { bundle in
                    guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
                          let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
                    else { return nil }
                    return plist["CFBundleIdentifier"] as? String
                }
        }
    }

    /// Whether nothing on the Mac owns an entry named `base` (lowercased): it looks like a bundle id, isn't
    /// macOS's own, no app has that id or is the one it starts with, and no app's id starts with it (com.foo
    /// for com.foo.app). With `byVendor`, no app from its vendor is left either. A launch job (`startupItem`)
    /// doesn't count a vendor's stranded updater as its app.
    func isOrphan(_ base: String, byVendor: Bool, startupItem: Bool = false) -> Bool {
        let installed = startupItem ? idsWithoutStrandedHelpers : ids
        guard LeftoverFinder.looksLikeBundleID(base), !LeftoverFinder.isMacOSName(base),
              LeftoverFinder.owner(of: base, among: installed) == nil,
              !installed.contains(where: { $0.hasPrefix(base + ".") })
        else { return false }
        return !byVendor || !hasVendor(of: base)
    }

    /// Whether an app from the vendor of `id` is on the Mac.
    func hasVendor(of id: String) -> Bool {
        guard let vendor = Self.vendor(of: id) else { return false }
        return Self.isPresent(vendor, vendors: vendors, names: names)
    }

    /// By bundle id, or by an app named after the vendor ("VMware Fusion" for com.vmware) when the vendor's
    /// name has four letters or more.
    static func isPresent(_ vendor: String, vendors: Set<String>, names: [String]) -> Bool {
        if vendors.contains(vendor) { return true }
        let name = vendorName(vendor)
        guard name.count >= 4 else { return false }
        return names.contains { app in app == name || [" ", ".", "-"].contains { app.hasPrefix(name + $0) } }
    }

    /// Second-level domains under a country's, as in uk.co.foo or br.com.foo.
    static let countryDomains: Set<String> = ["ac", "co", "com", "edu", "go", "gov", "ne", "net", "or", "org"]

    /// Who makes an app, from its lowercased id: com.vmware for com.vmware.fusion, br.com.nubank for
    /// br.com.nubank.app. Nil when the id has fewer parts than that.
    static func vendor(of id: String) -> String? {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        let size = parts.count >= 3 && parts[0].count == 2 && countryDomains.contains(String(parts[1])) ? 3 : 2
        guard parts.count >= size, parts.prefix(size).allSatisfy({ !$0.isEmpty }) else { return nil }
        return parts.prefix(size).joined(separator: ".")
    }

    /// "vmware" for com.vmware.
    static func vendorName(_ vendor: String) -> String {
        String(vendor.split(separator: ".").last ?? "")
    }
}
