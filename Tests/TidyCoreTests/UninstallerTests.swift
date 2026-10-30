import XCTest
@testable import TidyCore

final class UninstallerTests: XCTestCase {
    var tmp: URL!
    var library: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        library = tmp.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    @discardableResult
    private func makeApp(_ relative: String, bundleID: String, name: String? = nil, helpers: [String] = []) throws -> URL {
        let app = tmp.appendingPathComponent(relative)
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": "1.0"]
        if let name { plist["CFBundleName"] = name }
        if !helpers.isEmpty {
            plist["SMPrivilegedExecutables"] = Dictionary(uniqueKeysWithValues: helpers.map { ($0, "identifier \"\($0)\"") })
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        try Data(repeating: 0, count: 2048).write(to: contents.appendingPathComponent("MacOS/binary"))
        return app
    }

    @discardableResult
    private func makeLibraryEntry(_ relative: String, directory: Bool = false) throws -> URL {
        let url = library.appendingPathComponent(relative)
        if directory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url.appendingPathComponent("data"))
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        return url
    }

    private func names(_ items: [ScanItem]) -> Set<String> {
        // Resolve symlinks on both sides: macOS temp folders live behind /var -> /private/var.
        let root = library.resolvingSymlinksInPath().path + "/"
        return Set(items.map { $0.url.resolvingSymlinksInPath().path.replacingOccurrences(of: root, with: "") })
    }

    func testListsAppsIncludingOneFolderDown() throws {
        try makeApp("Applications/Foo.app", bundleID: "com.foo.app", name: "Foo")
        try makeApp("Applications/Utilities/Bar.app", bundleID: "com.bar.app")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("Applications/Broken.app"), withIntermediateDirectories: true)

        let apps = AppInventory.apps(in: [tmp.appendingPathComponent("Applications")])
        XCTAssertEqual(apps.map(\.bundleID), ["com.bar.app", "com.foo.app"])
        XCTAssertEqual(apps.first?.name, "Bar", "falls back to the bundle's file name")
    }

    func testWatchesTheFoldersItReadsAppsFrom() throws {
        try makeApp("Applications/Foo.app", bundleID: "com.foo.app")
        try makeApp("Applications/Utilities/Bar.app", bundleID: "com.bar.app")
        let applications = tmp.appendingPathComponent("Applications")
        let watched = AppInventory.foldersHoldingApps([applications, tmp.appendingPathComponent("Missing")])
        XCTAssertEqual(watched.map(\.lastPathComponent).sorted(), ["Applications", "Utilities"])
    }

    func testListsIPhoneAndIPadAppsInstalledOnTheMac() throws {
        // Their Info.plist sits in Wrapper/<name>.app, not in Contents.
        let inner = tmp.appendingPathComponent("Applications/Liminal.app/Wrapper/Liminal.app")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.liminal", "CFBundleDisplayName": "Liminal"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: inner.appendingPathComponent("Info.plist"))
        try Data().write(to: tmp.appendingPathComponent("Applications/Liminal.app/Wrapper/iTunesMetadata.plist"))

        let apps = AppInventory.apps(in: [tmp.appendingPathComponent("Applications")])
        XCTAssertEqual(apps.map(\.name), ["Liminal"])
        XCTAssertEqual(apps.first?.bundleID, "com.example.liminal")
        XCTAssertEqual(apps.first?.isFromAppStore, true)
    }

    func testFindsLeftoversByBundleIDAndPreselectsThem() throws {
        let expected: Set<String> = [
            "Application Support/com.foo.app",
            "Caches/com.foo.app",
            "Preferences/com.foo.app.plist",
            "Preferences/ByHost/com.foo.app.1234-ABCD.plist",
            "Containers/com.foo.app",
            "Group Containers/TEAM123.com.foo.app",
            "Saved Application State/com.foo.app.savedState",
            "Cookies/com.foo.app.binarycookies",
            "LaunchAgents/com.foo.app.helper.plist",
        ]
        for path in expected {
            try makeLibraryEntry(path, directory: !path.contains(".plist") && !path.hasSuffix("cookies"))
        }
        let items = LeftoverFinder(library: library).leftovers(bundleID: "com.foo.app", appName: "Foo", installedBundleIDs: ["com.foo.app"])
        XCTAssertEqual(names(items), expected)
        XCTAssertTrue(items.allSatisfy(\.isSelected))
    }

    func testNameMatchesArePreselectedUnlessTheNameIsTooShortToTell() throws {
        try makeLibraryEntry("Application Support/Foo", directory: true)
        try makeLibraryEntry("Preferences/Foo.plist")
        let items = LeftoverFinder(library: library).leftovers(bundleID: "com.foo.app", appName: "Foo", installedBundleIDs: [])
        XCTAssertEqual(names(items), ["Application Support/Foo"])
        XCTAssertTrue(items[0].isSelected)

        try makeLibraryEntry("Caches/Go", directory: true)
        let short = LeftoverFinder(library: library).leftovers(bundleID: "com.go.app", appName: "Go", installedBundleIDs: [])
        XCTAssertEqual(names(short), ["Caches/Go"])
        XCTAssertFalse(short[0].isSelected, "a two-letter name is left for you to check")
    }

    func testFindsCrashReportsRecentDocumentsAndGroupContainers() throws {
        let recents = "Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"
        let expected: Set<String> = [
            "Logs/DiagnosticReports/Foo-2026-10-28-101500.ips",
            "Logs/DiagnosticReports/Foo_2026-10-28-101500_MacBook-Pro.crash",
            recents + "/com.foo.app.sfl3",
            "Group Containers/group.com.foo.app",
        ]
        for path in expected { try makeLibraryEntry(path, directory: path.hasPrefix("Group")) }
        try makeLibraryEntry("Logs/DiagnosticReports/Foobar-2026-10-28-101500.ips")   // another app
        try makeLibraryEntry("Logs/DiagnosticReports/Foo-notes.txt")                   // not a report
        try makeLibraryEntry(recents + "/com.other.app.sfl3")
        try makeLibraryEntry("Group Containers/group.com.foo", directory: true)        // the vendor's, shared

        let items = LeftoverFinder(library: library).leftovers(bundleID: "com.foo.app", appName: "Foo", installedBundleIDs: [])
        XCTAssertEqual(names(items), expected)
        XCTAssertTrue(items.allSatisfy(\.isSelected))
        XCTAssertEqual(LeftoverFinder.baseName("com.foo.app.sfl2"), "com.foo.app")
    }

    func testFindsLaunchJobsThatRunTheAppAndTheHelpersItInstalled() throws {
        let appURL = try makeApp("Applications/Foo.app", bundleID: "com.foo.app", name: "Foo", helpers: ["com.vendor.installer"])
        func job(_ relative: String, program: String) throws {
            let url = library.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let plist: [String: Any] = ["Label": url.deletingPathExtension().lastPathComponent, "ProgramArguments": [program]]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        }
        let tools = library.appendingPathComponent("PrivilegedHelperTools")
        try job("LaunchAgents/com.vendor.updater.plist", program: appURL.path + "/Contents/MacOS/updater")
        try job("LaunchDaemons/com.vendor.installer.plist", program: tools.appendingPathComponent("com.vendor.installer").path)
        try job("LaunchDaemons/com.foo.app.sync.plist", program: tools.appendingPathComponent("FooSync").path)
        try makeLibraryEntry("PrivilegedHelperTools/com.vendor.installer")
        try makeLibraryEntry("PrivilegedHelperTools/FooSync")
        // Someone else's: a job running another app, and a tool no job of this app runs.
        try job("LaunchAgents/com.other.agent.plist", program: tmp.appendingPathComponent("Applications/Other.app/Contents/MacOS/agent").path)
        try job("LaunchAgents/com.sneaky.plist", program: appURL.path + "-evil/Contents/MacOS/agent")
        try makeLibraryEntry("PrivilegedHelperTools/com.other.tool")

        let items = LeftoverFinder(library: library).leftovers(bundleID: "com.foo.app", appName: "Foo", installedBundleIDs: [], appURL: appURL)
        XCTAssertEqual(names(items), [
            "LaunchAgents/com.vendor.updater.plist",
            "LaunchDaemons/com.vendor.installer.plist",
            "LaunchDaemons/com.foo.app.sync.plist",
            "PrivilegedHelperTools/com.vendor.installer",
            "PrivilegedHelperTools/FooSync",
        ])
        XCTAssertTrue(items.allSatisfy(\.isSelected))
        XCTAssertEqual(items.filter { $0.url.lastPathComponent == "FooSync" }.count, 1, "listed once")

        let none = LeftoverFinder(library: library).leftovers(bundleID: "com.foo.app", appName: "Foo", installedBundleIDs: [])
        XCTAssertEqual(names(none), ["LaunchDaemons/com.foo.app.sync.plist", "PrivilegedHelperTools/FooSync"],
                       "without the app, only what's named after it, and the tool its job runs")
    }

    func testCrashReportNames() {
        XCTAssertTrue(LeftoverFinder.isReport("foo-2026-10-28-101500.ips", of: "foo"))
        XCTAssertTrue(LeftoverFinder.isReport("foo bar_2026-10-28-101500.hang", of: "foo bar"))
        XCTAssertFalse(LeftoverFinder.isReport("foobar-2026-10-28-101500.ips", of: "foo"))
        XCTAssertFalse(LeftoverFinder.isReport("foo-2026-10-28-101500.txt", of: "foo"))
        XCTAssertFalse(LeftoverFinder.isReport("go-2026-10-28-101500.ips", of: "go"), "too short to tell")
    }

    func testNeverTakesAnotherInstalledAppsData() throws {
        try makeLibraryEntry("Application Support/com.foo.app.pro", directory: true)
        try makeLibraryEntry("Application Support/com.foo.application", directory: true)
        try makeLibraryEntry("Group Containers/TEAM123.com.foo", directory: true)
        let items = LeftoverFinder(library: library).leftovers(bundleID: "com.foo.app", appName: "Foo",
                                                               installedBundleIDs: ["com.foo.app", "com.foo.app.pro"])
        XCTAssertTrue(items.isEmpty, "found \(names(items))")
    }

    func testBundleIDMatchingIgnoresCase() throws {
        try makeLibraryEntry("Caches/com.Foo.App", directory: true)
        let items = LeftoverFinder(library: library).leftovers(bundleID: "com.foo.app", appName: "Foo", installedBundleIDs: [])
        XCTAssertEqual(items.count, 1)
    }

    func testUninstallMovesAppAndLeftoversToQuarantineAndCanBeUndone() async throws {
        let appURL = try makeApp("Applications/Foo.app", bundleID: "com.foo.app", name: "Foo")
        let prefs = try makeLibraryEntry("Preferences/com.foo.app.plist")
        let documents = try makeLibraryEntry("../Documents/Foo notes.txt")
        let app = try XCTUnwrap(InstalledApp(bundleURL: appURL))

        let scanner = UninstallScanner(app: app, finder: LeftoverFinder(library: library), installedBundleIDs: [app.bundleID])
        let items = try await scanner.scan { _ in }
        XCTAssertEqual(items.first?.category, "Application")
        XCTAssertEqual(items.count, 2)

        let store = QuarantineStore(root: tmp.appendingPathComponent("Quarantine"))
        let result = try await QuarantineCleaner(store: store, safePaths: scanner.safePaths).clean(items, dryRun: false)
        XCTAssertEqual(result.removed.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: appURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefs.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: documents.path))

        _ = try store.restore(batchID: try XCTUnwrap(result.batch).id)
        XCTAssertNotNil(InstalledApp(bundleURL: appURL), "the app is back and still readable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prefs.path))
    }

    func testUninstallAllowlistCoversOnlyTheAppAndLibraryLeftovers() throws {
        let appURL = try makeApp("Applications/Foo.app", bundleID: "com.foo.app")
        let other = try makeApp("Applications/Other.app", bundleID: "com.other.app")
        let app = try XCTUnwrap(InstalledApp(bundleURL: appURL))
        let safe = UninstallScanner(app: app, finder: LeftoverFinder(library: library), installedBundleIDs: []).safePaths
        XCTAssertTrue(safe.permits(appURL))
        XCTAssertTrue(safe.permits(library.appendingPathComponent("Caches/com.foo.app")))
        XCTAssertFalse(safe.permits(other))
        XCTAssertFalse(safe.permits(tmp.appendingPathComponent("Documents/file")))
    }

    func testBundleIDShape() {
        XCTAssertTrue(LeftoverFinder.looksLikeBundleID("com.example.app"))
        XCTAssertTrue(LeftoverFinder.looksLikeBundleID("org.mozilla.firefox-beta"))
        XCTAssertFalse(LeftoverFinder.looksLikeBundleID("com.example"))
        XCTAssertFalse(LeftoverFinder.looksLikeBundleID("My App 2.0.1"))
        XCTAssertFalse(LeftoverFinder.looksLikeBundleID("com..app"))
    }
}
