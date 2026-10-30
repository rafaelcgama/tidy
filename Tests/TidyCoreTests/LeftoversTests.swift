import XCTest
@testable import TidyCore

/// What removed apps leave behind, as System Junk finds it: in a fake home Library and a fake /Library.
final class LeftoversTests: XCTestCase {
    var tmp: URL!
    var library: URL!
    var systemLibrary: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        // No symlink in the path, so the helper policy below matches (macOS's temporary folder is behind /var).
        let base = try XCTUnwrap(SecureFileOps.realPath(fm.temporaryDirectory.path))
        tmp = URL(fileURLWithPath: base).appendingPathComponent("tidy-leftovers-\(UUID().uuidString)")
        library = tmp.appendingPathComponent("home/Library")
        systemLibrary = tmp.appendingPathComponent("SystemLibrary")
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        try fm.createDirectory(at: systemLibrary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tmp)
    }

    private func app(_ relative: String, _ bundleID: String, name: String? = nil) throws -> InstalledApp {
        let url = tmp.appendingPathComponent(relative)
        var plist: [String: Any] = ["CFBundleIdentifier": bundleID]
        if let name { plist["CFBundleName"] = name }
        try write(plist, to: url.appendingPathComponent("Contents/Info.plist"))
        return try XCTUnwrap(InstalledApp(bundleURL: url))
    }

    @discardableResult
    private func entry(_ relative: String, in folder: URL? = nil, directory: Bool = false) throws -> URL {
        let url = (folder ?? library).appendingPathComponent(relative)
        let file = directory ? url.appendingPathComponent("data") : url
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        return url
    }

    @discardableResult
    private func job(_ relative: String, in folder: URL? = nil, label: String? = nil, program: String) throws -> URL {
        let url = (folder ?? library).appendingPathComponent(relative)
        try write(["Label": label ?? url.deletingPathExtension().lastPathComponent, "Program": program], to: url)
        return url
    }

    private func write(_ plist: [String: Any], to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }

    /// The helper accepts what the real one would from the fake /Library.
    private var policy: HelperPolicy {
        HelperPolicy(folders: [
            .init(systemLibrary.appendingPathComponent("LaunchDaemons").path, suffixes: [".plist"], refusedPrefixes: ["com.apple."]),
            .init(systemLibrary.appendingPathComponent("PrivilegedHelperTools").path, refusedPrefixes: ["com.apple."]),
            .init(systemLibrary.appendingPathComponent("Application Support").path, refusedPrefixes: ["com.apple.", "apple"]),
            .init(systemLibrary.appendingPathComponent("Preferences").path, suffixes: [".plist"], refusedPrefixes: ["com.apple."]),
        ])
    }

    private func scan(_ apps: [InstalledApp], policy: HelperPolicy? = nil) async throws -> [ScanItem] {
        let scanner = OrphanedLeftoversScanner(finder: LeftoverFinder(library: library),
                                               systemFinder: LeftoverFinder(library: systemLibrary, shared: true),
                                               apps: { apps }, policy: policy ?? self.policy)
        let items = try await scanner.scan { _ in }
        XCTAssertTrue(items.allSatisfy { $0.category == LeftoverFinder.orphanCategory })
        XCTAssertTrue(items.allSatisfy { scanner.safePaths.permits($0.url) })
        return items
    }

    /// Paths relative to the temporary folder, and whether each is selected.
    private func found(_ items: [ScanItem]) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.url.path.replacingOccurrences(of: tmp.path + "/", with: ""), $0.isSelected) })
    }

    func testLeftoversOfAnAppWhoseVendorHasNothingLeft() async throws {
        let foo = try app("Applications/Foo.app", "com.foo.app")
        try entry("Application Support/com.gone.app", directory: true)
        try entry("Preferences/com.gone.app.plist")
        try entry("Saved Application State/com.gone.app.savedState", directory: true)
        try entry("HTTPStorages/com.gone.app", directory: true)
        try entry("Cookies/com.gone.app.binarycookies")
        // Not leftovers: macOS's own, the installed app's, folders that don't name an app, logs, and a container
        // (macOS would ask before Tidy looks inside).
        try entry("Containers/com.gone.app", directory: true)
        try entry("Caches/com.apple.Safari", directory: true)
        try entry("Preferences/org.cups.PrintingPrefs.plist")
        try entry("Preferences/com.foo.app.plist")
        try entry("Caches/com.foo.app.helper", directory: true)
        try entry("Application Support/com.foo", directory: true)
        try entry("Application Support/SomeFolder", directory: true)
        try entry("Logs/com.gone.app", directory: true)

        let items = try await scan([foo])
        XCTAssertEqual(found(items), [
            "home/Library/Application Support/com.gone.app": false,
            "home/Library/Preferences/com.gone.app.plist": false,
            // Window state, web caches and cookies can't matter, even if the app were somewhere Tidy doesn't see.
            "home/Library/Saved Application State/com.gone.app.savedState": true,
            "home/Library/HTTPStorages/com.gone.app": true,
            "home/Library/Cookies/com.gone.app.binarycookies": true,
        ])
    }

    func testWhatAVendorsAppsShareStaysWhileOneIsInstalled() async throws {
        let chrome = try app("Applications/Google Chrome.app", "com.google.Chrome")
        try entry("Preferences/com.google.Keystone.Agent.plist")
        try entry("Application Support/com.google.Drive", directory: true)
        // Only Drive made these, and Drive is gone.
        try entry("Saved Application State/com.google.Drive.savedState", directory: true)
        try entry("Application Scripts/com.google.Drive", directory: true)

        let items = try await scan([chrome])
        XCTAssertEqual(found(items), [
            "home/Library/Saved Application State/com.google.Drive.savedState": true,
            "home/Library/Application Scripts/com.google.Drive": false,
        ])
    }

    func testWhatAnAppCarriesInsideIsntALeftover() async throws {
        let onePassword = try app("Applications/1Password.app", "com.1password.1password")
        try write(["CFBundleIdentifier": "com.1password.safari"],
                  to: onePassword.url.appendingPathComponent("Contents/PlugIns/Safari.appex/Contents/Info.plist"))
        try entry("HTTPStorages/com.1password.safari", directory: true)
        try entry("HTTPStorages/com.1password.gone-extension", directory: true)

        let items = try await scan([onePassword])
        XCTAssertEqual(Array(found(items).keys), ["home/Library/HTTPStorages/com.1password.gone-extension"])
    }

    func testAVendorWhoseAppGoesByAnotherIDCountsByTheAppsName() async throws {
        let dropbox = try app("Applications/Dropbox.app", "com.getdropbox.dropbox", name: "Dropbox")
        try entry("Preferences/com.dropbox.DropboxMacUpdate.plist")
        try entry("Preferences/com.zzz.gone.plist")

        let items = try await scan([dropbox])
        XCTAssertEqual(Array(found(items).keys), ["home/Library/Preferences/com.zzz.gone.plist"])
    }

    func testCountryDomainsKeepTheCompanysName() async throws {
        XCTAssertEqual(KnownApps.vendor(of: "com.vmware.fusion"), "com.vmware")
        XCTAssertEqual(KnownApps.vendor(of: "br.com.nubank.app"), "br.com.nubank")
        XCTAssertEqual(KnownApps.vendor(of: "uk.co.bbc.iplayer"), "uk.co.bbc")
        XCTAssertEqual(KnownApps.vendor(of: "io.github.someone.tool"), "io.github")
        XCTAssertNil(KnownApps.vendor(of: "com"))

        let nubank = try app("Applications/Nubank.app", "br.com.nubank.app")
        try entry("Preferences/br.com.nubank.widget.plist")
        try entry("Preferences/br.com.itau.app.plist")
        let items = try await scan([nubank])
        XCTAssertEqual(Array(found(items).keys), ["home/Library/Preferences/br.com.itau.app.plist"])
    }

    func testStartupItemsThatStartNothingAreSelected() async throws {
        let program = try entry("bin/live-agent")
        // Outside the temporary folder, which Protection would warn about.
        let dead = try job("LaunchAgents/com.gone.agent.plist", program: "/Applications/TidyTestGone-\(UUID().uuidString).app/Contents/MacOS/agent")
        // A Homebrew service whose formula was removed is a leftover too.
        try job("LaunchAgents/homebrew.mxcl.redis.plist", program: "/opt/homebrew/opt/redis/bin/redis-server-gone")
        // Not leftovers: macOS's, one that runs, one on a disk that isn't plugged in, one launchd resolves,
        // and one Protection warns about (it would start a program from a temporary folder).
        try job("LaunchAgents/com.apple.gone.plist", program: "/System/Gone")
        try job("LaunchAgents/com.mine.backup.plist", program: program.path)
        try job("LaunchAgents/com.disk.agent.plist", program: "/Volumes/Backup/agent")
        try job("LaunchAgents/com.relative.agent.plist", program: "agent")
        try job("LaunchAgents/com.temp.agent.plist", program: "/tmp/tidy-test-gone-\(UUID().uuidString)")

        let items = try await scan([])
        XCTAssertEqual(found(items), [
            "home/Library/LaunchAgents/com.gone.agent.plist": true,
            "home/Library/LaunchAgents/homebrew.mxcl.redis.plist": true,
        ])
        XCTAssertEqual(items.first { $0.url == dead }?.label, "com.gone.agent.plist (starts nothing: its program is gone)")
    }

    func testARemovedVendorsHelperAndFoldersAreListed() async throws {
        let foo = try app("Applications/Foo.app", "com.foo.app")
        let helper = try entry("PrivilegedHelperTools/com.vmware.DiskHelper", in: systemLibrary)
        let daemon = try job("LaunchDaemons/com.vmware.DiskHelper.plist", in: systemLibrary, program: helper.path)
        try entry("Application Support/VMware", in: systemLibrary, directory: true)
        try entry("Application Support/VMware Fusion", directory: true)
        try entry("Preferences/VMware Fusion", directory: true)
        try entry("Preferences/com.vmware.fusion.plist")
        // Not leftovers: the installed app's helper, a printer driver's monitor (not in a support folder),
        // and a folder that only starts with the vendor's name.
        let fooHelper = try entry("PrivilegedHelperTools/com.foo.helper", in: systemLibrary)
        try job("LaunchDaemons/com.foo.helper.plist", in: systemLibrary, program: fooHelper.path)
        try job("LaunchDaemons/com.hp.devicemonitor.plist", in: systemLibrary, program: try entry("Printers/hp/monitor").path)
        try entry("Application Support/VMwareish", directory: true)

        let items = try await scan([foo])
        XCTAssertEqual(found(items), [
            "SystemLibrary/LaunchDaemons/com.vmware.DiskHelper.plist": false,
            "SystemLibrary/PrivilegedHelperTools/com.vmware.DiskHelper": false,
            "SystemLibrary/Application Support/VMware": false,
            "home/Library/Application Support/VMware Fusion": false,
            "home/Library/Preferences/VMware Fusion": false,
            "home/Library/Preferences/com.vmware.fusion.plist": false,
        ])
        XCTAssertEqual(items.first { $0.url == daemon }?.label, "com.vmware.DiskHelper.plist (starts a removed app's helper)")

        // From /Library, only what the admin helper accepts is offered.
        let refused = try await scan([foo], policy: HelperPolicy(folders: []))
        XCTAssertFalse(refused.contains { $0.url.path.hasPrefix(systemLibrary.path + "/") })

        // With a VMware app installed, none of it is a leftover.
        let fusion = try app("Applications/VMware Fusion.app", "com.vmware.fusion")
        let none = try await scan([foo, fusion])
        XCTAssertTrue(none.isEmpty, "\(found(none))")
    }

    func testAnUpdaterLeftInLibraryDoesntKeepItsVendorsStartupItems() async throws {
        let updater = try app("SystemLibrary/Application Support/Google/GoogleUpdater/GoogleUpdater.app", "com.google.GoogleUpdater")
        try job("LaunchDaemons/com.google.GoogleUpdater.wake.system.plist", in: systemLibrary,
                program: try entry("Contents/MacOS/GoogleUpdater", in: updater.url).path)
        try entry("Preferences/com.google.GoogleUpdater.plist")

        // Chrome is gone, so what starts its updater is a leftover, and so is the Google folder the updater is in.
        // The updater's settings stay as long as it's there.
        let items = try await scan([updater])
        XCTAssertEqual(found(items), [
            "SystemLibrary/LaunchDaemons/com.google.GoogleUpdater.wake.system.plist": false,
            "SystemLibrary/Application Support/Google": false,
        ])

        let chrome = try app("Applications/Google Chrome.app", "com.google.Chrome")
        let none = try await scan([updater, chrome])
        XCTAssertTrue(none.isEmpty, "\(found(none))")
    }

    func testSystemJunkListsLeftoversAndInstallersInDownloads() async throws {
        let home = tmp.appendingPathComponent("home")
        try entry("Saved Application State/com.tidytest.removed.savedState", directory: true)
        let installer = home.appendingPathComponent("Downloads/Removed.dmg")
        try entry("Removed.dmg", in: installer.deletingLastPathComponent())

        let scanner = CombinedScanner.systemJunk(home: home, systemLocations: [], applicationFolders: [], systemLibrary: nil)
        let items = try await scanner.scan { _ in }
        XCTAssertEqual(Set(items.map(\.category)), [LeftoverFinder.orphanCategory, DownloadedInstallersScanner.category])
        XCTAssertTrue(scanner.safePaths.permits(installer))
        XCTAssertTrue(scanner.safePaths.permits(library.appendingPathComponent("Saved Application State/com.tidytest.removed.savedState")))
        XCTAssertFalse(scanner.safePaths.permits(home.appendingPathComponent("Downloads/notes.txt")))
    }

    func testInstallersInDownloadsAreSelectedAWeekAfterTheDownload() async throws {
        let downloads = tmp.appendingPathComponent("Downloads")
        let old = try entry("Old.dmg", in: downloads)
        try fm.backdate(old, days: 10)
        try entry("New.PKG", in: downloads)
        try entry("Xcode.xip", in: downloads)
        try entry("notes.txt", in: downloads)
        try entry("Photos.zip", in: downloads)

        let scanner = DownloadedInstallersScanner(folder: downloads)
        let items = try await scanner.scan { _ in }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: items.map { ($0.url.lastPathComponent, $0.isSelected) }),
                       ["Old.dmg": true, "New.PKG": false, "Xcode.xip": false])
        XCTAssertTrue(scanner.safePaths.permits(old))
        XCTAssertFalse(scanner.safePaths.permits(downloads.appendingPathComponent("notes.txt")))
        XCTAssertFalse(scanner.safePaths.permits(downloads))
    }
}
