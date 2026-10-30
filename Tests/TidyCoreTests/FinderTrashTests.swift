import XCTest
@testable import TidyCore

/// Open Trash asks Finder for its Trash. A stand-in osascript takes the place of macOS's.
final class FinderTrashTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tidy-trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Keeps the script it was given, one word a line, and ends as macOS's would.
    private func osascript(exit status: Int32) throws -> URL {
        let url = tmp.appendingPathComponent("osascript")
        let body = """
            #!/bin/sh
            printf '%s\\n' "$@" > "$(dirname "$0")/script.txt"
            [ \(status) -eq 0 ] || echo '0:0: execution error: Not authorized to send Apple events to Finder. (-1743)' >&2
            exit \(status)
            """
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testAsksFinderToOpenItsTrash() throws {
        XCTAssertTrue(FinderTrash(osascript: try osascript(exit: 0)).open())
        let script = try String(contentsOf: tmp.appendingPathComponent("script.txt"), encoding: .utf8)
        XCTAssertEqual(script, "-e\ntell application \"Finder\"\n-e\nopen trash\n-e\nactivate\n-e\nend tell\n")
    }

    func testSaysSoWhenMacOSDoesNotLetTidyAskFinder() throws {
        XCTAssertFalse(FinderTrash(osascript: try osascript(exit: 1)).open())
    }

    func testSaysSoWithoutOsascript() {
        XCTAssertFalse(FinderTrash(osascript: tmp.appendingPathComponent("missing")).open())
    }
}
