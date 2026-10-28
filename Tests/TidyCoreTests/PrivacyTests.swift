import XCTest
@testable import TidyCore

final class PrivacyTests: XCTestCase {
    var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    @discardableResult
    private func write(_ relative: String, _ text: String = "data") throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private let chrome = "Library/Application Support/Google/Chrome"
    private let firefox = "Library/Application Support/Firefox/Profiles"

    private func names(_ items: [ScanItem]) -> Set<String> {
        Set(items.map { $0.url.path.replacingOccurrences(of: home.path + "/", with: "") })
    }

    func testChromiumProfilesListPrivacyDataButNeverPasswordsOrBookmarks() async throws {
        for profile in ["Default", "Profile 1"] {
            try write("\(chrome)/\(profile)/Preferences")
            try write("\(chrome)/\(profile)/History")
            try write("\(chrome)/\(profile)/Network/Cookies")
            try write("\(chrome)/\(profile)/Web Data")
            try write("\(chrome)/\(profile)/Sessions/Session_1")
            try write("\(chrome)/\(profile)/Login Data")
            try write("\(chrome)/\(profile)/Bookmarks")
        }
        try write("\(chrome)/Guest Profile/Preferences")
        try write("\(chrome)/Guest Profile/History")      // not a real profile
        try write("\(chrome)/Profile 2/History")          // no Preferences, not a profile

        let scanner = PrivacyScanner(home: home)
        let items = try await scanner.scan { _ in }
        XCTAssertEqual(names(items), [
            "\(chrome)/Default/History", "\(chrome)/Default/Network/Cookies", "\(chrome)/Default/Web Data", "\(chrome)/Default/Sessions",
            "\(chrome)/Profile 1/History", "\(chrome)/Profile 1/Network/Cookies", "\(chrome)/Profile 1/Web Data", "\(chrome)/Profile 1/Sessions",
        ])
        XCTAssertTrue(items.allSatisfy { !$0.isSelected }, "nothing is preselected")
        XCTAssertTrue(items.contains { $0.category == "Google Chrome (Profile 1): Browsing and download history" })
        XCTAssertTrue(items.allSatisfy { scanner.safePaths.permits($0.url) })
        for kept in ["Login Data", "Bookmarks", "Preferences"] {
            XCTAssertFalse(scanner.safePaths.permits(home.appendingPathComponent("\(chrome)/Default/\(kept)")), kept)
        }
    }

    func testSingleProfileHasNoLabel() async throws {
        try write("\(chrome)/Default/Preferences")
        try write("\(chrome)/Default/History")
        let items = try await PrivacyScanner(home: home).scan { _ in }
        XCTAssertEqual(items.map(\.category), ["Google Chrome: Browsing and download history"])
    }

    func testFirefoxLeavesHistoryBookmarksAndPasswordsAlone() async throws {
        let profile = "\(firefox)/ab12cd34.default-release"
        for file in ["prefs.js", "cookies.sqlite", "formhistory.sqlite", "sessionstore.jsonlz4",
                     "places.sqlite", "logins.json", "key4.db"] {
            try write("\(profile)/\(file)")
        }
        try write("\(firefox)/not-a-profile/cookies.sqlite")
        let items = try await PrivacyScanner(home: home).scan { _ in }
        XCTAssertEqual(names(items), ["\(profile)/cookies.sqlite", "\(profile)/formhistory.sqlite", "\(profile)/sessionstore.jsonlz4"])
    }

    func testSafariAndRecentItems() async throws {
        try write("Library/Safari/History.db")
        try write("Library/Safari/History.db-wal")
        try write("Library/Safari/Bookmarks.plist")
        try write("Library/Safari/Downloads.plist")
        try write("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
        try write("Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.RecentDocuments.sfl3")
        try write("Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/com.apple.textedit.sfl3")
        try write("Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.FavoriteItems.sfl3")  // Finder sidebar

        let items = try await PrivacyScanner(home: home).scan { _ in }
        XCTAssertEqual(names(items), [
            "Library/Safari/History.db", "Library/Safari/History.db-wal", "Library/Safari/Downloads.plist",
            "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
            "Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.RecentDocuments.sfl3",
            "Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments",
        ])
        XCTAssertEqual(Set(items.filter { $0.url.path.contains("sharedfilelist") }.map(\.category)),
                       ["macOS: Recent items (Apple menu, Finder and apps)"])
    }

    func testBrowsersOwningItems() async throws {
        try write("\(chrome)/Default/Preferences")
        try write("\(chrome)/Default/Cookies")
        try write("\(firefox)/x.default/prefs.js")
        try write("\(firefox)/x.default/cookies.sqlite")
        try write("Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.RecentDocuments.sfl3")
        let scanner = PrivacyScanner(home: home)
        let items = try await scanner.scan { _ in }
        XCTAssertEqual(scanner.browsers(owning: items).map(\.name), ["Google Chrome", "Firefox"])
        XCTAssertEqual(scanner.browsers(owning: items.filter { $0.url.path.contains("sharedfilelist") }), [])
    }

    func testCleaningMovesOnlySelectedDataAndCanBeUndone() async throws {
        try write("\(chrome)/Default/Preferences")
        let history = try write("\(chrome)/Default/History", "visits")
        let cookies = try write("\(chrome)/Default/Cookies", "cookies")
        let passwords = try write("\(chrome)/Default/Login Data", "secret")
        let scanner = PrivacyScanner(home: home)
        var items = try await scanner.scan { _ in }
        for index in items.indices where items[index].url.lastPathComponent == "History" {
            items[index].isSelected = true
        }
        // A forged item outside the allowlist is refused even if selected.
        items.append(ScanItem(url: passwords, size: 6, category: "forged", isSelected: true))

        let store = QuarantineStore(root: home.appendingPathComponent("Quarantine"))
        let result = try await QuarantineCleaner(store: store, safePaths: scanner.safePaths).clean(items, dryRun: false)
        XCTAssertEqual(result.removed.map(\.url.lastPathComponent), ["History"])
        XCTAssertEqual(result.skipped.map(\.item.url.lastPathComponent), ["Login Data"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cookies.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: passwords.path))

        _ = try store.restore(batchID: try XCTUnwrap(result.batch).id)
        XCTAssertEqual(try String(contentsOf: history, encoding: .utf8), "visits")
    }
}
