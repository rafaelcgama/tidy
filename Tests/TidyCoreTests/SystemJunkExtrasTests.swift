import XCTest
@testable import TidyCore

/// A temporary folder that the test removes when it's done.
private func makeTemporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writePlist(_ plist: [String: Any], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
}

private func writeBytes(_ count: Int, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 1, count: count).write(to: url)
}

final class DeviceBackupScannerTests: XCTestCase {
    var home: URL!
    var backups: URL { home.appendingPathComponent("Library/Application Support/MobileSync/Backup") }

    override func setUpWithError() throws { home = try makeTemporaryFolder() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func backup(_ id: String, info: [String: Any]?) throws {
        try writeBytes(8192, to: backups.appendingPathComponent("\(id)/00/00112233445566"))
        if let info { try writePlist(info, to: backups.appendingPathComponent("\(id)/Info.plist")) }
    }

    func testListsBackupsByDeviceAndSelectsNone() async throws {
        let date = Date(timeIntervalSince1970: 1_740_000_000)
        try backup("00008030-001A", info: ["Device Name": "Work iPhone", "Last Backup Date": date])
        try backup("00008101-002B", info: ["Display Name": "iPad"])
        try backup("00008030-001A-20240101-101010", info: nil)
        let items = try await DeviceBackupScanner(home: home).scan { _ in }

        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items.allSatisfy { !$0.isSelected && $0.size > 0 && $0.category == "iPhone and iPad backups" },
                      "a backup may be the only copy of a device's data")
        let labels = Dictionary(uniqueKeysWithValues: items.map { ($0.url.lastPathComponent, $0.label ?? "-") })
        XCTAssertTrue(labels["00008030-001A"]?.hasPrefix("Work iPhone, backed up ") == true, labels.description)
        XCTAssertEqual(labels["00008101-002B"], "iPad")
        XCTAssertEqual(labels["00008030-001A-20240101-101010"], "-", "no Info.plist: the folder name shows")
        XCTAssertEqual(items.first { $0.url.lastPathComponent == "00008030-001A" }?.lastModified, date)
    }

    func testSkipsFilesAndSymlinksAndAllowsOnlyTheBackupFolder() async throws {
        try writeBytes(4096, to: backups.appendingPathComponent("stray.txt"))
        try writeBytes(4096, to: home.appendingPathComponent("Documents/letter.txt"))
        try FileManager.default.createSymbolicLink(at: backups.appendingPathComponent("link"),
                                                   withDestinationURL: home.appendingPathComponent("Documents"))
        let scanner = DeviceBackupScanner(home: home)
        let items = try await scanner.scan { _ in }
        XCTAssertTrue(items.isEmpty)
        XCTAssertTrue(scanner.safePaths.permits(backups.appendingPathComponent("00008030-001A")))
        XCTAssertFalse(scanner.safePaths.permits(home.appendingPathComponent("Documents/letter.txt")))
    }
}

final class MacInstallerScannerTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws { folder = try makeTemporaryFolder() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func app(_ name: String, bundleID: String) throws {
        let contents = folder.appendingPathComponent("\(name).app/Contents")
        try writePlist(["CFBundleIdentifier": bundleID, "CFBundleDisplayName": name], to: contents.appendingPathComponent("Info.plist"))
        try writeBytes(65_536, to: contents.appendingPathComponent("SharedSupport/SharedSupport.dmg"))
    }

    func testSelectsInstallersForTheRunningMacOSOrOlder() async throws {
        try app("Install macOS Sonoma", bundleID: "com.apple.InstallAssistant.macOSSonoma")
        try app("Install macOS Sequoia", bundleID: "com.apple.InstallAssistant.macOSSequoia")
        try app("Install OS X El Capitan", bundleID: "com.apple.InstallAssistant.ElCapitan")
        try app("Install macOS Tahoe", bundleID: "com.apple.InstallAssistant.macOSTahoe")
        try app("Install macOS Someday", bundleID: "com.apple.InstallAssistant.macOSSomeday")
        try app("Install Helper", bundleID: "com.example.installhelper")
        try app("Safari", bundleID: "com.apple.Safari")
        let scanner = MacInstallerScanner(folders: [folder], runningVersion: [15, 6])
        let items = try await scanner.scan { _ in }

        let selected = Dictionary(uniqueKeysWithValues: items.map { ($0.url.deletingPathExtension().lastPathComponent, $0.isSelected) })
        XCTAssertEqual(selected, ["Install macOS Sonoma": true, "Install macOS Sequoia": true, "Install OS X El Capitan": true,
                                  "Install macOS Tahoe": false, "Install macOS Someday": false],
                       "a newer macOS, or one Tidy doesn't know yet, may be about to be installed")
        XCTAssertTrue(items.allSatisfy { $0.category == "macOS installers" && $0.size > 0 })
        XCTAssertTrue(scanner.safePaths.permits(folder.appendingPathComponent("Install macOS Sonoma.app")))
        XCTAssertFalse(scanner.safePaths.permits(folder.appendingPathComponent("Install Helper.app")))
        XCTAssertFalse(scanner.safePaths.permits(folder.appendingPathComponent("Safari.app")))
    }

    func testReadsTheVersionFromTheInstallerName() {
        XCTAssertEqual(MacInstallerScanner.version(ofInstallerNamed: "Install macOS High Sierra"), [10, 13])
        XCTAssertEqual(MacInstallerScanner.version(ofInstallerNamed: "Install macOS Sierra"), [10, 12])
        XCTAssertEqual(MacInstallerScanner.version(ofInstallerNamed: "Install macOS Big Sur Beta"), [11])
        XCTAssertNil(MacInstallerScanner.version(ofInstallerNamed: "Install macOS Someday"))
    }
}

final class SimulatorScannerTests: XCTestCase {
    var home: URL!
    var devices: URL { home.appendingPathComponent("Library/Developer/CoreSimulator/Devices") }

    override func setUpWithError() throws { home = try makeTemporaryFolder() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func simulator(_ udid: String, name: String, runtime: String) throws {
        try writePlist(["UDID": udid, "name": name, "runtime": "com.apple.CoreSimulator.SimRuntime.\(runtime)", "state": 1],
                       to: devices.appendingPathComponent("\(udid)/device.plist"))
        try writeBytes(8192, to: devices.appendingPathComponent("\(udid)/data/Library/blob"))
    }

    private let simctlOutput = """
    {"devices": {
      "com.apple.CoreSimulator.SimRuntime.iOS-18-0": [{"udid": "AAAA", "isAvailable": true, "name": "iPhone 16", "state": "Shutdown"}],
      "com.apple.CoreSimulator.SimRuntime.iOS-15-5": [{"udid": "BBBB", "isAvailable": false, "name": "iPhone 8", "state": "Shutdown",
                                                       "availabilityError": "runtime profile not found"}]
    }}
    """

    func testSelectsSimulatorsXcodeCanNoLongerRun() async throws {
        try simulator("AAAA", name: "iPhone 16", runtime: "iOS-18-0")
        try simulator("BBBB", name: "iPhone 8", runtime: "iOS-15-5")
        try writePlist(["DefaultDevices": [String: Any]()], to: devices.appendingPathComponent("device_set.plist"))
        let output = simctlOutput
        let items = try await SimulatorScanner(home: home, listDevices: { output }).scan { _ in }

        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.url.lastPathComponent, $0) })
        XCTAssertEqual(Set(byID.keys), ["AAAA", "BBBB"], "device_set.plist stays")
        XCTAssertEqual(byID["AAAA"]?.isSelected, false)
        XCTAssertEqual(byID["AAAA"]?.label, "iPhone 16, iOS 18.0")
        XCTAssertEqual(byID["BBBB"]?.isSelected, true)
        XCTAssertEqual(byID["BBBB"]?.label, "iPhone 8, iOS 15.5 (no longer in Xcode)")
        XCTAssertTrue(items.allSatisfy { $0.category == "Xcode simulators" && $0.size > 0 })
    }

    func testSelectsNothingWhenXcodeDoesNotAnswer() async throws {
        try simulator("BBBB", name: "iPhone 8", runtime: "iOS-15-5")
        let items = try await SimulatorScanner(home: home, listDevices: { nil }).scan { _ in }
        XCTAssertEqual(items.map(\.isSelected), [false])
        XCTAssertEqual(items.first?.label, "iPhone 8, iOS 15.5")
    }

    func testAsksXcodeOnlyWhenThereAreSimulators() async throws {
        let asked = Recorder<Bool>()
        let items = try await SimulatorScanner(home: home, listDevices: { asked.add(true); return nil }).scan { _ in }
        XCTAssertTrue(items.isEmpty)
        XCTAssertTrue(asked.all.isEmpty)
    }

    func testRuntimeNames() {
        XCTAssertEqual(SimulatorScanner.runtimeName("com.apple.CoreSimulator.SimRuntime.watchOS-10-2"), "watchOS 10.2")
        XCTAssertEqual(SimulatorScanner.runtimeName("odd"), "odd")
    }
}

final class CombinedScannerTests: XCTestCase {
    func testSystemJunkAddsBackupsAndInstallers() async throws {
        let home = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Caches/com.example")
        try writeBytes(4096, to: cache.appendingPathComponent("blob"))
        let backup = home.appendingPathComponent("Library/Application Support/MobileSync/Backup/00008030-001A")
        try writeBytes(4096, to: backup.appendingPathComponent("00/0011"))
        let applications = home.appendingPathComponent("Applications")
        let installer = applications.appendingPathComponent("Install macOS Sonoma.app")
        try writePlist(["CFBundleIdentifier": "com.apple.InstallAssistant.macOSSonoma"],
                       to: installer.appendingPathComponent("Contents/Info.plist"))

        let scanner = CombinedScanner.systemJunk(home: home, systemLocations: [], applicationFolders: [applications])
        let items = try await scanner.scan { _ in }
        XCTAssertEqual(Set(items.map(\.category)), ["User caches", "iPhone and iPad backups", "macOS installers"])
        XCTAssertTrue(scanner.safePaths.permits(cache))
        XCTAssertTrue(scanner.safePaths.permits(backup))
        XCTAssertTrue(scanner.safePaths.permits(installer))
        XCTAssertFalse(scanner.safePaths.permits(applications.appendingPathComponent("Safari.app")))
    }
}

final class TrashTests: XCTestCase {
    var home: URL!
    var trashFolder: URL { home.appendingPathComponent(".Trash") }

    override func setUpWithError() throws { home = try makeTemporaryFolder() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    func testListsWhatIsInTheTrashLargestFirst() throws {
        try writeBytes(4096, to: trashFolder.appendingPathComponent("notes.txt"))
        try writeBytes(65_536, to: trashFolder.appendingPathComponent("Old App.app/Contents/MacOS/Old App"))
        try writeBytes(10, to: trashFolder.appendingPathComponent(".DS_Store"))
        let items = try XCTUnwrap(Trash(home: home).items())
        XCTAssertEqual(items.map(\.url.lastPathComponent), ["Old App.app", "notes.txt"])
        XCTAssertTrue(items.allSatisfy { $0.isSelected && $0.category == "Trash" })
    }

    func testNoTrashFolderMeansAnEmptyTrash() {
        XCTAssertEqual(Trash(home: home).items()?.count, 0)
    }

    func testEmptyingDeletesOnlyWhatIsInTheTrash() throws {
        try writeBytes(4096, to: trashFolder.appendingPathComponent("notes.txt"))
        try writeBytes(4096, to: home.appendingPathComponent("Documents/keep.txt"))
        try FileManager.default.createSymbolicLink(at: trashFolder.appendingPathComponent("link"),
                                                   withDestinationURL: home.appendingPathComponent("Documents"))
        let trash = Trash(home: home)
        let outside = ScanItem(url: home.appendingPathComponent("Documents/keep.txt"), size: 4096, category: "Trash")
        let sneaky = ScanItem(url: URL(fileURLWithPath: trashFolder.path + "/../Documents/keep.txt"), size: 4096, category: "Trash")
        let result = try trash.empty(try XCTUnwrap(trash.items()) + [outside, sneaky])

        XCTAssertEqual(Set(result.deleted.map(\.url.lastPathComponent)), ["notes.txt", "link"])
        XCTAssertEqual(result.skipped.count, 2)
        XCTAssertEqual(trash.items()?.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("Documents/keep.txt").path),
                      "a link in the Trash goes, not what it points to")

        let lines = try String(contentsOf: trash.log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("\"action\":\"start\""))
        XCTAssertTrue(lines[1].contains("\"action\":\"deleted\"") && lines[1].contains("notes.txt"))
    }

    func testNothingIsDeletedWhenTheLogCantBeWritten() throws {
        try writeBytes(4096, to: trashFolder.appendingPathComponent("notes.txt"))
        // A file where the log's folder should be.
        try writeBytes(1, to: home.appendingPathComponent("Library/Application Support/Tidy"))
        let trash = Trash(home: home)
        XCTAssertThrowsError(try trash.empty(try XCTUnwrap(trash.items())))
        XCTAssertEqual(trash.items()?.count, 1)
    }
}
