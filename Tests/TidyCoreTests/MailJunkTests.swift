import XCTest
@testable import TidyCore

/// Mark Junk and Trash as Read asks Mail to mark the unread messages in Junk and Trash, in every account. A stand-in
/// osascript takes the place of macOS's.
final class MailJunkTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tidy-mail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Keeps the script it was given, one argument a line, and answers as macOS's would.
    private func osascript(prints output: String = "", complains errors: String = "", exit status: Int32 = 0) throws -> URL {
        let url = tmp.appendingPathComponent("osascript")
        let body = """
            #!/bin/sh
            printf '%s\\n' "$@" > "$(dirname "$0")/script.txt"
            printf '%s' '\(output)'
            printf '%s' '\(errors)' >&2
            exit \(status)
            """
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testAsksMailToMarkEveryAccountsJunkAndTrashAsRead() throws {
        XCTAssertEqual(MailJunk(osascript: try osascript(prints: "12\n")).markRead(), .marked(12))
        let passed = try String(contentsOf: tmp.appendingPathComponent("script.txt"), encoding: .utf8)
        XCTAssertEqual(passed, MailJunk.script.map { "-e\n\($0)\n" }.joined())
        XCTAssertEqual(MailJunk.script.first, "tell application id \"com.apple.mail\"")
        XCTAssertTrue(MailJunk.script.contains { $0.contains("every mailbox of junk mailbox") })
        XCTAssertTrue(MailJunk.script.contains { $0.contains("every mailbox of trash mailbox") })
        XCTAssertTrue(MailJunk.script.contains { $0.contains("set end of theBoxes to trash mailbox") })
        XCTAssertTrue(MailJunk.script.contains { $0.contains("set read status of every message of theBox whose read status is false to true") })
    }

    func testSaysSoWhenJunkAndTrashHaveNothingUnread() throws {
        XCTAssertEqual(MailJunk(osascript: try osascript(prints: "0\n")).markRead(), .marked(0))
    }

    func testSaysSoWhenMacOSDoesNotLetTidyControlMail() throws {
        let refused = try osascript(complains: "0:0: execution error: Not authorized to send Apple events to Mail. (-1743)\n", exit: 1)
        XCTAssertEqual(MailJunk(osascript: refused).markRead(), .notAllowed)
    }

    func testSaysWhatMailSaidWhenItFails() throws {
        let failed = try osascript(complains: "780:822: execution error: Mail got an error: AppleEvent timed out. (-1712)\n", exit: 1)
        XCTAssertEqual(MailJunk(osascript: failed).markRead(), .failed("Mail got an error: AppleEvent timed out."))
    }

    func testSaysSoWithoutOsascript() {
        XCTAssertEqual(MailJunk(osascript: tmp.appendingPathComponent("missing")).markRead(), .failed("Tidy couldn't ask Mail."))
    }

    #if os(macOS)
    /// Every word the script uses is in Mail's own dictionary, which only a Mac has.
    func testScriptCompilesWithMailsDictionary() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/System/Applications/Mail.app"), "Mail isn't on this Mac")
        let osacompile = URL(fileURLWithPath: "/usr/bin/osacompile")
        let result = try Subprocess.run(osacompile, ["-o", tmp.appendingPathComponent("junk.scpt").path] + MailJunk.arguments)
        XCTAssertEqual(result.status, 0, result.errors)
    }
    #endif
}
