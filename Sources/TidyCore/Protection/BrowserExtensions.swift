import Foundation

/// An extension installed in a browser. Extensions can see what you do on websites, so Protection lists them all.
public struct BrowserExtension: Identifiable, Hashable, Sendable {
    /// The browser, and its profile when it has more than one.
    public let browser: String
    public let name: String
    public let version: String?
    /// Its folder or file; for Safari, the app extension it comes in.
    public let url: URL
    /// It may read and change everything on every website.
    public let readsAllSites: Bool
    /// The app a Safari extension comes with.
    public let app: String?

    public var id: String { url.path }
}

/// Finds the extensions of Safari, Firefox and the Chromium browsers (Chrome, Brave, Edge, Arc, Vivaldi, Opera).
public struct BrowserExtensionReader: Sendable {
    public let home: URL
    /// What `pluginkit -mAv -p <kind>` prints for one of Safari's extension kinds; nil when it can't run.
    let pluginKit: @Sendable (String) -> String?

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                pluginKit: @escaping @Sendable (String) -> String? = BrowserExtensionReader.runPluginKit) {
        self.home = home
        self.pluginKit = pluginKit
    }

    public static let runPluginKit: @Sendable (String) -> String? = { kind in
        guard let result = try? Subprocess.run(URL(fileURLWithPath: "/usr/bin/pluginkit"), ["-mAv", "-p", kind]), result.status == 0
        else { return nil }
        return result.output
    }

    /// Browser by browser, as the Privacy module lists them, and by name within each.
    public func extensions() -> [BrowserExtension] {
        let privacy = PrivacyScanner(home: home)
        var found: [BrowserExtension] = []
        for browser in PrivacyScanner.browsers {
            if browser.layout == .safari {
                found += safariExtensions().sorted(by: Self.byName)
                continue
            }
            for (profile, label) in privacy.profiles(of: browser) {
                let name = label.map { "\(browser.name) (\($0))" } ?? browser.name
                let extensions = browser.layout == .firefox
                    ? firefoxExtensions(in: profile, browser: name)
                    : chromiumExtensions(in: profile.appendingPathComponent("Extensions"), browser: name)
                found += extensions.sorted(by: Self.byName)
            }
        }
        return found
    }

    static func byName(_ lhs: BrowserExtension, _ rhs: BrowserExtension) -> Bool {
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    // MARK: - Chromium

    /// Extensions/<id>/<version>/manifest.json, one folder per extension.
    func chromiumExtensions(in folder: URL, browser: String) -> [BrowserExtension] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter(Self.isChromiumID).map { id in
            let idFolder = folder.appendingPathComponent(id)
            // Usually one version; while the browser runs, an update can wait next to the old one.
            let version = ((try? fm.contentsOfDirectory(atPath: idFolder.path)) ?? [])
                .filter { fm.fileExists(atPath: idFolder.appendingPathComponent($0).appendingPathComponent("manifest.json").path) }
                .max { $0.compare($1, options: .numeric) == .orderedAscending }
            let versionFolder = version.map { idFolder.appendingPathComponent($0) }
            let manifest = versionFolder.flatMap { Self.json($0.appendingPathComponent("manifest.json")) as? [String: Any] } ?? [:]
            let name = versionFolder.flatMap { Self.localized(manifest["name"] as? String, in: $0, defaultLocale: manifest["default_locale"] as? String) }
            return BrowserExtension(browser: browser, name: name ?? id, version: manifest["version"] as? String, url: idFolder,
                                    readsAllSites: Self.readsAllSites(manifest), app: nil)
        }
    }

    /// Chromium extension ids are 32 letters from a to p.
    static func isChromiumID(_ name: String) -> Bool {
        name.count == 32 && name.allSatisfy { ("a"..."p").contains($0) }
    }

    /// Whether a WebExtension manifest asks for every website, in its permissions or the pages its scripts run on.
    static func readsAllSites(_ manifest: [String: Any]) -> Bool {
        let patterns = (manifest["permissions"] as? [Any] ?? []) + (manifest["host_permissions"] as? [Any] ?? [])
            + (manifest["content_scripts"] as? [[String: Any]] ?? []).flatMap { $0["matches"] as? [Any] ?? [] }
        return patterns.contains { ($0 as? String).map(isAllSites) ?? false }
    }

    /// "<all_urls>", "*://*/*", "https://*/*" and the like: any page of any website.
    static func isAllSites(_ pattern: String) -> Bool {
        if pattern == "<all_urls>" { return true }
        guard let range = pattern.range(of: "://") else { return false }
        return pattern[range.upperBound...].prefix { $0 != "/" } == "*"
    }

    /// Resolves a name like "__MSG_appName__" from _locales/<locale>/messages.json, as the browser shows it.
    static func localized(_ text: String?, in folder: URL, defaultLocale: String?) -> String? {
        guard let text, text.hasPrefix("__MSG_"), text.hasSuffix("__"), text.count > 8 else { return text }
        let key = text.dropFirst(6).dropLast(2).lowercased()
        for locale in [defaultLocale, "en", "en_US"].compactMap({ $0 }) {
            let messages = json(folder.appendingPathComponent("_locales/\(locale)/messages.json")) as? [String: Any] ?? [:]
            // Message names aren't case-sensitive.
            if let entry = messages.first(where: { $0.key.lowercased() == key })?.value as? [String: Any],
               let message = entry["message"] as? String {
                return message
            }
        }
        return nil
    }

    // MARK: - Firefox

    /// What the profile's extensions.json lists, except Firefox's own built-in add-ons.
    func firefoxExtensions(in profile: URL, browser: String) -> [BrowserExtension] {
        let builtIn: Set<String> = ["app-builtin", "app-system-defaults", "app-system-addons"]
        guard let list = Self.json(profile.appendingPathComponent("extensions.json")) as? [String: Any],
              let addons = list["addons"] as? [[String: Any]]
        else { return [] }
        return addons.compactMap { addon in
            guard addon["type"] as? String == "extension", let id = addon["id"] as? String,
                  !builtIn.contains(addon["location"] as? String ?? "")
            else { return nil }
            let origins = (addon["userPermissions"] as? [String: Any])?["origins"] as? [String] ?? []
            return BrowserExtension(browser: browser, name: (addon["defaultLocale"] as? [String: Any])?["name"] as? String ?? id,
                                    version: addon["version"] as? String,
                                    url: (addon["path"] as? String).map { URL(fileURLWithPath: $0) }
                                        ?? profile.appendingPathComponent("extensions/\(id).xpi"),
                                    readsAllSites: origins.contains(where: Self.isAllSites), app: nil)
        }
    }

    // MARK: - Safari

    /// Safari's extensions come inside apps, registered with macOS as app extensions of two kinds.
    func safariExtensions() -> [BrowserExtension] {
        var seen: Set<String> = []
        var found: [BrowserExtension] = []
        for kind in ["com.apple.Safari.web-extension", "com.apple.Safari.extension"] {
            for appex in Self.pluginPaths(in: pluginKit(kind) ?? "") where seen.insert(appex.path).inserted {
                let info = Self.plist(appex.appendingPathComponent("Contents/Info.plist"))
                let readsAllSites: Bool
                if kind == "com.apple.Safari.web-extension" {
                    readsAllSites = Self.readsAllSites(Self.json(appex.appendingPathComponent("Contents/Resources/manifest.json")) as? [String: Any] ?? [:])
                } else {
                    // The older kind says in its Info.plist how many websites it may see.
                    let access = (info["NSExtension"] as? [String: Any])?["SFSafariWebsiteAccess"] as? [String: Any]
                    readsAllSites = access?["Level"] as? String == "All"
                }
                found.append(BrowserExtension(browser: "Safari",
                                              name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
                                                  ?? appex.deletingPathExtension().lastPathComponent,
                                              version: info["CFBundleShortVersionString"] as? String, url: appex,
                                              readsAllSites: readsAllSites,
                                              app: appex.pathComponents.first { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }))
            }
        }
        return found
    }

    /// The .appex paths in pluginkit's listing, one per line after the extension's id, version and date.
    static func pluginPaths(in output: String) -> [URL] {
        output.split(separator: "\n").compactMap { line in
            guard let range = line.range(of: #"/.*\.appex"#, options: .regularExpression) else { return nil }
            return URL(fileURLWithPath: String(line[range]))
        }
    }

    static func json(_ url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func plist(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:]
    }
}
