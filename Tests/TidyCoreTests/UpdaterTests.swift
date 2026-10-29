import XCTest
@testable import TidyCore

final class UpdaterTests: XCTestCase {
    func testVersionOrdering() {
        let ordered = ["1.0b1", "1.0b2", "1.0", "1.0.1", "1.9", "1.10", "2.0-rc1", "2.0", "10"]
        for (older, newer) in zip(ordered, ordered.dropFirst()) {
            XCTAssertTrue(VersionComparator.isNewer(newer, than: older), "\(newer) should be newer than \(older)")
            XCTAssertFalse(VersionComparator.isNewer(older, than: newer), "\(older) should be older than \(newer)")
        }
        XCTAssertEqual(VersionComparator.compare("1.0", "1.0"), .orderedSame)
        XCTAssertEqual(VersionComparator.compare("1.0", "1.0.0"), .orderedAscending)
        XCTAssertEqual(VersionComparator.compare("2024.10.1", "2024.9.30"), .orderedDescending)
    }

    let appcast = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <title>Example</title>
        <item>
          <title>Version 2.1</title>
          <sparkle:version>210</sparkle:version>
          <sparkle:shortVersionString>2.1</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
          <sparkle:releaseNotesLink>https://example.invalid/notes/2.1</sparkle:releaseNotesLink>
          <enclosure url="https://example.invalid/Example-2.1.zip" length="1000" type="application/octet-stream"/>
        </item>
        <item>
          <title>Version 2.0</title>
          <enclosure url="https://example.invalid/Example-2.0.zip" sparkle:version="200" sparkle:shortVersionString="2.0"/>
        </item>
        <item>
          <title>Version 3.0 beta</title>
          <sparkle:version>300</sparkle:version>
          <sparkle:channel>beta</sparkle:channel>
          <enclosure url="https://example.invalid/Example-3.0b.zip"/>
        </item>
        <item>
          <title>Version 2.5 for macOS 15</title>
          <sparkle:version>250</sparkle:version>
          <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
          <enclosure url="https://example.invalid/Example-2.5.zip"/>
        </item>
      </channel>
    </rss>
    """.utf8)

    func testParsesAppcastItemsFromElementsAndEnclosureAttributes() {
        let items = AppcastParser.parse(appcast)
        XCTAssertEqual(items.map(\.version), ["210", "200", "300", "250"])
        XCTAssertEqual(items[0].shortVersion, "2.1")
        XCTAssertEqual(items[0].downloadURL?.absoluteString, "https://example.invalid/Example-2.1.zip")
        XCTAssertEqual(items[0].releaseNotesURL?.absoluteString, "https://example.invalid/notes/2.1")
        XCTAssertEqual(items[1].shortVersion, "2.0")
        XCTAssertEqual(items[2].channel, "beta")
    }

    func testLatestSkipsBetasAndReleasesThisMacCantRun() {
        let items = AppcastParser.parse(appcast)
        XCTAssertEqual(AppcastParser.latest(in: items, osVersion: "14.6")?.version, "210")
        XCTAssertEqual(AppcastParser.latest(in: items, osVersion: "15.1")?.version, "250")
        XCTAssertNil(AppcastParser.latest(in: AppcastParser.parse(Data("not xml".utf8)), osVersion: "14.0"))
    }

    private func makeApp(in folder: URL, name: String, build: String, short: String, feed: String?) throws -> InstalledApp {
        let app = folder.appendingPathComponent("\(name).app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleIdentifier": "com.example.\(name)", "CFBundleVersion": build, "CFBundleShortVersionString": short]
        if let feed { plist["SUFeedURL"] = feed }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return try XCTUnwrap(InstalledApp(bundleURL: app))
    }

    func testCheckerReportsOnlyAppsWithNewerReleases() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = try makeApp(in: folder, name: "Old", build: "200", short: "2.0", feed: "https://example.invalid/old.xml")
        let current = try makeApp(in: folder, name: "Current", build: "210", short: "2.1", feed: "https://example.invalid/current.xml")
        let offline = try makeApp(in: folder, name: "Offline", build: "1", short: "1.0", feed: "https://example.invalid/offline.xml")
        let noFeed = try makeApp(in: folder, name: "NoFeed", build: "1", short: "1.0", feed: nil)
        let appcast = self.appcast

        let checker = SparkleUpdateChecker { url in
            if url.lastPathComponent == "offline.xml" { throw URLError(.notConnectedToInternet) }
            return appcast
        }
        let updates = await checker.check([old, current, offline, noFeed], osVersion: "14.6")
        XCTAssertEqual(updates.map(\.app.name), ["Old"])
        XCTAssertEqual(updates.first?.currentVersion, "2.0")
        XCTAssertEqual(updates.first?.item.displayVersion, "2.1")
    }

    func testParsesHomebrewOutdatedCasks() {
        let json = Data("""
        {"formulae": [], "casks": [
          {"name": "visual-studio-code", "installed_versions": ["1.93.0"], "current_version": "1.94.2"},
          {"name": "firefox", "installed_versions": ["130.0"], "current_version": "131.0.3"}
        ]}
        """.utf8)
        let casks = OutdatedCask.parse(json)
        XCTAssertEqual(casks.map(\.token), ["firefox", "visual-studio-code"])
        XCTAssertEqual(casks[1].installedVersion, "1.93.0")
        XCTAssertEqual(casks[1].currentVersion, "1.94.2")
        XCTAssertTrue(OutdatedCask.parse(Data("oops".utf8)).isEmpty)
    }

    // MARK: - Tidy's own releases

    let release = Data("""
    {"tag_name": "build-202610291200", "name": "Tidy 1.1.0", "body": "Simpler Performance tab",
     "html_url": "https://github.com/rafaelcgama/clean-my-mac/releases/tag/build-202610291200",
     "assets": [{"name": "notes.txt", "browser_download_url": "https://example.invalid/notes.txt"},
                {"name": "Tidy.dmg", "browser_download_url": "https://example.invalid/Tidy.dmg"}]}
    """.utf8)

    func testReadsTidysLatestRelease() throws {
        let latest = try XCTUnwrap(TidyRelease.parse(release))
        XCTAssertEqual(latest.version, "1.1.0")
        XCTAssertEqual(latest.build, 202610291200)
        XCTAssertEqual(latest.notes, "Simpler Performance tab")
        XCTAssertEqual(latest.downloadURL.absoluteString, "https://example.invalid/Tidy.dmg")
        XCTAssertTrue(latest.isNewer(thanBuild: 202610290500))
        XCTAssertFalse(latest.isNewer(thanBuild: 202610291200))
        XCTAssertFalse(latest.isNewer(thanBuild: 202610300900), "a build made later on this Mac is already newer")
        XCTAssertFalse(latest.isNewer(thanBuild: nil), "a copy run from Xcode isn't offered updates")
    }

    func testIgnoresReleasesThatArentTidyBuilds() {
        let otherTag = Data(String(decoding: release, as: UTF8.self).replacingOccurrences(of: "build-202610291200\"", with: "v2\"").utf8)
        XCTAssertNil(TidyRelease.parse(otherTag))
        let noImage = Data(String(decoding: release, as: UTF8.self).replacingOccurrences(of: "\"Tidy.dmg\"", with: "\"Tidy.zip\"").utf8)
        XCTAssertNil(TidyRelease.parse(noImage))
        XCTAssertNil(TidyRelease.parse(Data("not json".utf8)))
    }

    func testNoReleaseYetIsNotAnError() async throws {
        let none = try await TidyRelease.latest { _ in (Data(#"{"message": "Not Found"}"#.utf8), 404) }
        XCTAssertNil(none)
        let found = try await TidyRelease.latest { [release] url in
            XCTAssertEqual(url, TidyRelease.latestURL)
            return (release, 200)
        }
        XCTAssertEqual(found?.build, 202610291200)
        do {
            _ = try await TidyRelease.latest { _ in (Data(), 403) }
            XCTFail("a refused check should throw")
        } catch {
            XCTAssertTrue(error is TidyRelease.CheckFailed)
        }
    }

    func testCaskUpdatesAreAsGreedyAsTheListing() {
        // Without --greedy, brew skips casks that say they update themselves (gcloud-cli), so Update did nothing.
        XCTAssertTrue(Homebrew.outdatedArguments.contains("--greedy"))
        XCTAssertEqual(Homebrew.upgradeArguments("gcloud-cli"), ["upgrade", "--cask", "--greedy", "gcloud-cli"])
    }
}
