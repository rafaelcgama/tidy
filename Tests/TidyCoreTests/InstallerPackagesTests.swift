import XCTest
@testable import TidyCore

final class InstallerPackagesTests: XCTestCase {
    /// Stands in for the startup disk: "/" in the fake receipts is this folder.
    var disk: URL!

    override func setUpWithError() throws {
        disk = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: disk)
    }

    @discardableResult
    private func file(_ relative: String, bytes: Int = 10) throws -> URL {
        let url = disk.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    /// The helper's folders, moved onto the fake disk.
    private var folders: [HelperPolicy.Folder] {
        HelperPolicy.systemFolders.map {
            HelperPolicy.Folder(disk.path + $0.path.replacingOccurrences(of: "/private/var", with: "/var"),
                                suffixes: $0.suffixes, refusedPrefixes: $0.refusedPrefixes, refusedNames: $0.refusedNames)
        }
    }

    /// pkgutil for one installed package, `id`, that installed `paths`. `shared` paths were installed
    /// by another package too.
    private func packages(id: String, paths: [String], shared: Set<String> = []) -> InstallerPackages {
        let root = disk.path
        let files = paths.joined(separator: "\n")
        return InstallerPackages(pkgutil: { arguments in
            switch arguments.first {
            case "--file-info":
                let path = arguments[1]
                let relative = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
                guard paths.contains(relative) else { return "volume: /\npath: \(path)\n" }
                var output = "volume: /\npath: \(path)\n\npkgid: \(id)\npkg-version: 1.0\n"
                if shared.contains(relative) { output += "\npkgid: com.other.pkg\npkg-version: 2.0\n" }
                return output
            case "--pkg-info":
                return arguments[1] == id ? "package-id: \(id)\nversion: 1.0\nvolume: \(root)\nlocation: \ninstall-time: 1700000000\n" : nil
            case "--files":
                return arguments[1] == id ? files : nil
            default:
                return nil
            }
        }, receiptsFolder: disk.appendingPathComponent("var/db/receipts"), folders: folders)
    }

    private func relative(_ items: [ScanItem]) -> [String: ScanItem] {
        Dictionary(uniqueKeysWithValues: items.map { (String($0.url.path.dropFirst(disk.path.count + 1)), $0) })
    }

    func testReadsWhatPkgutilPrints() {
        let fileInfo = """
        volume: /
        path: /Applications/Foo.app

        pkgid: com.foo.pkg.app
        pkg-version: 1.2

        pkgid: com.foo.pkg.driver
        pkg-version: 1.2
        """
        XCTAssertEqual(InstallerPackages.values(of: "pkgid", in: fileInfo), ["com.foo.pkg.app", "com.foo.pkg.driver"])

        let packages = InstallerPackages(pkgutil: { arguments in
            switch arguments {
            case ["--pkg-info", "com.foo.pkg.app"]: return "package-id: com.foo.pkg.app\nvolume: /\nlocation: Applications\n"
            case ["--files", "com.foo.pkg.app"]: return "Foo.app\nFoo.app/Contents\n\nFoo.app/Contents/Info.plist\n"
            default: return nil
            }
        })
        XCTAssertEqual(packages.receipt("com.foo.pkg.app"),
                       .init(id: "com.foo.pkg.app", root: "/Applications", paths: ["Foo.app", "Foo.app/Contents", "Foo.app/Contents/Info.plist"]))
        XCTAssertNil(packages.receipt("com.unknown.pkg"))
        XCTAssertEqual(InstallerPackages.join("/", ""), "/")
        XCTAssertEqual(InstallerPackages.join("/", "./Library/Foo"), "/Library/Foo")
        XCTAssertEqual(InstallerPackages.join("/Volumes/Data/", "Applications/"), "/Volumes/Data/Applications")
    }

    func testOffersWhatTheAppsPackagePutOutsideTheApp() throws {
        let app = try file("Applications/Foo.app/Contents/Info.plist").deletingLastPathComponent().deletingLastPathComponent()
        try file("Applications/Foo Helper.app/Contents/Info.plist")
        try file("Library/Audio/Plug-Ins/HAL/FooAudio.driver/Contents/Info.plist", bytes: 300)
        let settings = try file("Library/Application Support/Foo/settings")
        let later = try file("Library/Application Support/Foo/written-later.log")
        try file("Library/Application Support/Vendor/shared")
        try file("usr/local/bin/footool", bytes: 50)
        try file("usr/local/bin/othertool")
        try file("var/db/receipts/com.foo.pkg.bom")
        try file("var/db/receipts/com.foo.pkg.plist")
        let paths = [
            "Applications", "Applications/Foo.app", "Applications/Foo.app/Contents", "Applications/Foo.app/Contents/Info.plist",
            "Applications/Foo Helper.app", "Applications/Foo Helper.app/Contents", "Applications/Foo Helper.app/Contents/Info.plist",
            "Library", "Library/Audio", "Library/Audio/Plug-Ins", "Library/Audio/Plug-Ins/HAL",
            "Library/Audio/Plug-Ins/HAL/FooAudio.driver", "Library/Audio/Plug-Ins/HAL/FooAudio.driver/Contents",
            "Library/Audio/Plug-Ins/HAL/FooAudio.driver/Contents/Info.plist",
            "Library/Application Support", "Library/Application Support/Foo", "Library/Application Support/Foo/settings",
            "Library/Application Support/Vendor", "Library/Application Support/Vendor/shared",
            "Library/PreferencePanes", "Library/PreferencePanes/Foo.prefPane",
            "usr", "usr/local", "usr/local/bin", "usr/local/bin/footool",
        ]
        let packages = packages(id: "com.foo.pkg", paths: paths, shared: ["Library/Application Support/Vendor"])

        let found = relative(packages.leftovers(of: app))
        XCTAssertEqual(Set(found.keys), [
            "Library/Audio/Plug-Ins/HAL/FooAudio.driver",
            "Library/Application Support/Foo",
            "usr/local/bin/footool",
            "Applications/Foo Helper.app",
            "var/db/receipts/com.foo.pkg.bom",
            "var/db/receipts/com.foo.pkg.plist",
        ], "not the app itself, not a folder another package shares, not what's already gone, not the folders it was put in")
        XCTAssertEqual(found["Library/Audio/Plug-Ins/HAL/FooAudio.driver"]?.category, "Installer files")
        XCTAssertEqual(found["Library/Audio/Plug-Ins/HAL/FooAudio.driver"]?.isSelected, true)
        XCTAssertEqual(found["Library/Application Support/Foo"]?.size, DiskUsage.size(of: settings) + DiskUsage.size(of: later),
                       "files the app wrote later go with their folder")
        XCTAssertEqual(found["Applications/Foo Helper.app"]?.isSelected, false, "another app from the same package is your call")
        XCTAssertEqual(found["var/db/receipts/com.foo.pkg.bom"]?.category, "Installer receipts")
    }

    func testNothingForAnAppThatDidntComeFromAPackage() throws {
        let app = try file("Applications/Bar.app/Contents/Info.plist").deletingLastPathComponent().deletingLastPathComponent()
        try file("usr/local/bin/bartool")
        XCTAssertTrue(packages(id: "com.foo.pkg", paths: ["usr/local/bin/bartool"]).leftovers(of: app).isEmpty)
    }

    func testLeavesApplesReceiptsAndNamesTheHelperWouldRefuse() throws {
        let app = try file("Applications/Pages.app/Contents/Info.plist").deletingLastPathComponent().deletingLastPathComponent()
        try file("var/db/receipts/com.apple.pkg.Pages.bom")
        try file("Library/Audio/Plug-Ins/HAL/readme.txt")
        let paths = ["Applications/Pages.app", "Library/Audio/Plug-Ins/HAL/readme.txt"]
        XCTAssertTrue(packages(id: "com.apple.pkg.Pages", paths: paths).leftovers(of: app).isEmpty)
    }

    func testUninstallAddsPackageFilesOnceAndAllowsRemovingThem() async throws {
        let appURL = try file("Applications/Foo.app/Contents/Info.plist").deletingLastPathComponent().deletingLastPathComponent()
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.foo.app"], format: .xml, options: 0)
        try plist.write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        let app = try XCTUnwrap(InstalledApp(bundleURL: appURL))
        let daemon = try file("Library/LaunchDaemons/com.foo.app.helper.plist")
        let driver = try file("Library/Audio/Plug-Ins/HAL/FooAudio.driver/Contents/Info.plist").deletingLastPathComponent().deletingLastPathComponent()
        let paths = ["Applications/Foo.app", "Library/LaunchDaemons/com.foo.app.helper.plist",
                     "Library/Audio/Plug-Ins/HAL/FooAudio.driver", "Library/Audio/Plug-Ins/HAL/FooAudio.driver/Contents/Info.plist"]
        let scanner = UninstallScanner(app: app, finder: LeftoverFinder(library: disk.appendingPathComponent("Library")),
                                       packages: packages(id: "com.foo.pkg", paths: paths), installedBundleIDs: [app.bundleID])
        let items = try await scanner.scan { _ in }
        // macOS temp folders live behind /var -> /private/var, so compare resolved paths.
        func listed(_ url: URL) -> [ScanItem] {
            items.filter { $0.url.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path }
        }
        XCTAssertEqual(listed(daemon).count, 1, "found by bundle id and by the receipt, listed once")
        XCTAssertEqual(listed(driver).first?.category, "Installer files")
        XCTAssertTrue(scanner.safePaths.permits(driver))
        XCTAssertFalse(scanner.safePaths.permits(disk.appendingPathComponent("Users/someone/Documents/file")))
    }
}

final class AppUsageTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    func testLastOpenedText() {
        let now = date("2026-10-28T12:00:00Z")
        func text(_ opened: String?) -> String {
            AppUsage.text(lastOpened: opened.map(date), now: now, calendar: calendar)
        }
        XCTAssertEqual(text(nil), "Never opened")
        XCTAssertEqual(text("2026-10-28T08:00:00Z"), "Opened today")
        XCTAssertEqual(text("2026-10-27T23:00:00Z"), "Opened yesterday")
        XCTAssertEqual(text("2026-10-18T12:00:00Z"), "Opened 10 days ago")
        XCTAssertEqual(text("2026-09-20T12:00:00Z"), "Opened a month ago")
        XCTAssertEqual(text("2026-05-01T12:00:00Z"), "Opened 6 months ago")
        XCTAssertEqual(text("2025-10-01T12:00:00Z"), "Opened a year ago")
        XCTAssertEqual(text("2024-10-01T12:00:00Z"), "Opened 2 years ago")
        XCTAssertEqual(text("2026-10-29T09:00:00Z"), "Opened today", "a clock that moved back doesn't count backwards")
    }

    func testUnusedAfterSixMonthsOrNeverOpened() {
        let now = date("2026-10-28T12:00:00Z")
        XCTAssertTrue(AppUsage.isUnused(lastOpened: nil, now: now))
        XCTAssertTrue(AppUsage.isUnused(lastOpened: now.addingTimeInterval(-180 * 86_400), now: now))
        XCTAssertFalse(AppUsage.isUnused(lastOpened: now.addingTimeInterval(-179 * 86_400), now: now))
    }
}
