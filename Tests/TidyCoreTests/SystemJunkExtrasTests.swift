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
    func testSystemJunkAddsInstallers() async throws {
        let home = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Caches/com.example")
        try writeBytes(4096, to: cache.appendingPathComponent("blob"))
        let applications = home.appendingPathComponent("Applications")
        let installer = applications.appendingPathComponent("Install macOS Sonoma.app")
        try writePlist(["CFBundleIdentifier": "com.apple.InstallAssistant.macOSSonoma"],
                       to: installer.appendingPathComponent("Contents/Info.plist"))

        let scanner = CombinedScanner.systemJunk(home: home, systemLocations: [], applicationFolders: [applications], systemLibrary: nil)
        let items = try await scanner.scan { _ in }
        XCTAssertEqual(Set(items.map(\.category)), ["User caches", "macOS installers"])
        XCTAssertTrue(scanner.safePaths.permits(cache))
        XCTAssertTrue(scanner.safePaths.permits(installer))
        XCTAssertFalse(scanner.safePaths.permits(applications.appendingPathComponent("Safari.app")))
    }
}
