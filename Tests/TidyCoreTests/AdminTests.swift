import XCTest
@testable import TidyCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// What Tidy does as root without the admin helper: the password prompt, and Tidy run as root for one
/// request. Stand-in osascript scripts take the place of macOS's.
final class AdminTests: XCTestCase {
    var tmp: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        // A path without symlinks in it (on macOS the temporary folder sits behind the /var symlink).
        let base = try XCTUnwrap(SecureFileOps.realPath(fm.temporaryDirectory.path))
        tmp = URL(fileURLWithPath: base).appendingPathComponent("tidy-admin-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tmp)
    }

    @discardableResult
    private func write(_ relative: String, _ text: String) throws -> URL {
        let url = tmp.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    @discardableResult
    private func folder(_ relative: String) throws -> URL {
        let url = tmp.appendingPathComponent(relative)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func script(_ name: String, _ body: String) throws -> URL {
        let url = try write(name, "#!/bin/sh\n" + body + "\n")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: - The password prompt

    /// Runs the shell line the way `do shell script` does, keeping the line and the prompt it was given.
    private static let fakeOsascript = """
        dir=$(dirname "$0")
        printf '%s' "$7" > "$dir/line.txt"
        printf '%s' "$8" > "$dir/prompt.txt"
        if output=$(/bin/sh -c "$7" 2>&1); then printf '%s\\n' "$output"; exit 0; fi
        printf '0:0: execution error: %s (1)\\n' "$output" >&2
        exit 1
        """

    func testRunsEveryWordAsItIsAfterThePrompt() throws {
        let osascript = try script("osascript", Self.fakeOsascript)
        let odd = tmp.appendingPathComponent("it's \"odd\" $HOME; `false` & *")
        let output = try AdminPrompt(osascript: osascript).run([AdminPrompt.Step(["/usr/bin/touch", odd.path]),
                                                               AdminPrompt.Step(["/bin/echo", "done"])],
                                                              prompt: "Tidy needs an administrator's password to test.")
        XCTAssertEqual(output, "done")
        XCTAssertTrue(fm.fileExists(atPath: odd.path))
        XCTAssertEqual(try String(contentsOf: tmp.appendingPathComponent("prompt.txt"), encoding: .utf8),
                       "Tidy needs an administrator's password to test.")
    }

    func testAStepThatMayFailDoesntStopTheRest() throws {
        let osascript = try script("osascript", Self.fakeOsascript)
        let output = try AdminPrompt(osascript: osascript).run([AdminPrompt.Step(["/bin/sh", "-c", "exit 3"], mayFail: true),
                                                               AdminPrompt.Step(["/bin/echo", "after"])], prompt: "p")
        XCTAssertEqual(output, "after")
    }

    func testAFailedStepStopsTheRestAndSaysWhy() throws {
        let osascript = try script("osascript", Self.fakeOsascript)
        let marker = tmp.appendingPathComponent("marker")
        XCTAssertThrowsError(try AdminPrompt(osascript: osascript).run([AdminPrompt.Step(["/bin/sh", "-c", "echo nope >&2; exit 3"]),
                                                                       AdminPrompt.Step(["/usr/bin/touch", marker.path])],
                                                                      prompt: "p")) {
            XCTAssertEqual($0 as? AdminPrompt.Failure, .failed("nope"))
        }
        XCTAssertFalse(fm.fileExists(atPath: marker.path))
    }

    func testCancellingThePasswordPromptIsNotAFailure() throws {
        let osascript = try script("osascript", "echo '0:94: execution error: User canceled. (-128)' >&2\nexit 1")
        XCTAssertThrowsError(try AdminPrompt(osascript: osascript).run([AdminPrompt.Step(["/bin/echo", "x"])], prompt: "p")) {
            XCTAssertEqual($0 as? AdminPrompt.Failure, .cancelled)
        }
    }

    func testTheShellLineAndThePromptArriveAsData() {
        XCTAssertEqual(AdminPrompt.shellLine([AdminPrompt.Step(["/bin/echo", "it's"]), AdminPrompt.Step(["/usr/bin/true"], mayFail: true)]),
                       #"'/bin/echo' 'it'\''s' && { '/usr/bin/true' || true; }"#)
        let arguments = AdminPrompt.arguments([AdminPrompt.Step(["/usr/sbin/purge"])], prompt: "Why")
        XCTAssertEqual(Array(arguments.suffix(2)), ["'/usr/sbin/purge'", "Why"])
        XCTAssertFalse(arguments.dropLast(2).joined().contains("purge"), "never part of the script itself")
    }

    func testReadsAppleScriptErrors() {
        let cancelled = AppleScriptError("0:94: execution error: User canceled. (-128)\n")
        XCTAssertEqual(cancelled.message, "User canceled.")
        XCTAssertEqual(cancelled.code, -128)
        XCTAssertEqual(AppleScriptError("something odd").message, "something odd")
        XCTAssertNil(AppleScriptError("something odd").code)
        XCTAssertEqual(AppleScriptError("  \n").message, "The script didn't finish.")
    }

    // MARK: - Tidy run as root for one request

    private func makeService() throws -> PrivilegedService {
        let policy = HelperPolicy(folders: [.init(try folder("system/Library/Caches").path)])
        let store = QuarantineStore(root: tmp.appendingPathComponent("helper/Quarantine"), mover: SecureFileOps.mover)
        return PrivilegedService(policy: policy, store: store, trustedOwner: UInt32(geteuid()), run: { _ in })
    }

    private func run(_ request: AdminCommand.Request, on service: PrivilegedService) throws -> String {
        let arguments = ["/Applications/Tidy.app/Contents/MacOS/Tidy"] + (try AdminCommand.arguments(for: request))
        let handled = try XCTUnwrap(AdminCommand.handle(arguments, service: service, isRoot: true))
        XCTAssertEqual(handled.status, 0, handled.output)
        return handled.output
    }

    func testMovesPutsBackAndDeletesAsTheHelperWould() throws {
        let service = try makeService()
        let cache = try folder("system/Library/Caches/com.foo")
        try write("system/Library/Caches/com.foo/blob", "x")
        let item = HelperItem(path: cache.path, size: 1, category: "Caches")

        let batchID = QuarantineStore.makeBatchID(Date())
        let moved = try AdminCommand.reply(HelperQuarantineReply.self,
                                           from: try run(.quarantine(HelperQuarantineRequest(batchID: batchID, items: [item])), on: service))
        XCTAssertEqual(moved.batch?.entries.count, 1)
        XCTAssertFalse(fm.fileExists(atPath: cache.path))

        let restored = try AdminCommand.reply(HelperRestoreReply.self, from: try run(.restore(batchID: batchID), on: service))
        XCTAssertEqual(restored.restored.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: cache.appendingPathComponent("blob").path))

        let again = QuarantineStore.makeBatchID(Date())
        _ = try run(.quarantine(HelperQuarantineRequest(batchID: again, items: [item])), on: service)
        let deleted = try AdminCommand.reply([QuarantineBatch].self, from: try run(.delete(HelperDeleteRequest(batchIDs: [again])), on: service))
        XCTAssertEqual(deleted.map(\.id), [again])
        XCTAssertFalse(service.store.hasBatch(again))
        XCTAssertFalse(fm.fileExists(atPath: cache.path), "deleted for good")
    }

    func testRefusesWhatTheHelperRefuses() throws {
        let service = try makeService()
        let outside = try write("elsewhere/secret", "x")
        let request = HelperQuarantineRequest(batchID: QuarantineStore.makeBatchID(Date()),
                                              items: [HelperItem(path: outside.path, size: 1, category: "Caches")])
        let reply = try AdminCommand.reply(HelperQuarantineReply.self, from: try run(.quarantine(request), on: service))
        XCTAssertNil(reply.batch)
        XCTAssertEqual(reply.failed.map(\.path), [outside.path])
        XCTAssertTrue(fm.fileExists(atPath: outside.path))
    }

    func testOnlyTheFlagStartsItAndOnlyAsRoot() throws {
        let service = try makeService()
        XCTAssertNil(AdminCommand.handle(["Tidy"], service: service, isRoot: true))
        // What Xcode passes when it runs the app.
        XCTAssertNil(AdminCommand.handle(["Tidy", "-NSDocumentRevisionsDebugMode", "YES"], service: service, isRoot: true))
        XCTAssertEqual(AdminCommand.handle(["Tidy", AdminCommand.flag], service: service, isRoot: true)?.status, 64)
        let restore = try AdminCommand.arguments(for: .restore(batchID: QuarantineStore.makeBatchID(Date())))
        XCTAssertEqual(AdminCommand.handle(["Tidy"] + restore, service: service, isRoot: false)?.status, 77)
        XCTAssertEqual(AdminCommand.handle(["Tidy", AdminCommand.flag, "{not json"], service: service, isRoot: true)?.status, 1)
        XCTAssertEqual(AdminCommand.handle(["Tidy"] + restore, service: service, isRoot: true)?.status, 1, "no such batch")
    }

    // MARK: - Launch agents

    func testOnlyAgentsAreStoppedAndStartedInYourSession() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertTrue(LaunchJobControl.isAgent(home.appendingPathComponent("Library/LaunchAgents/com.foo.plist"), home: home))
        XCTAssertTrue(LaunchJobControl.isAgent(URL(fileURLWithPath: "/Library/LaunchAgents/com.foo.plist"), home: home))
        XCTAssertFalse(LaunchJobControl.isAgent(URL(fileURLWithPath: "/Library/LaunchDaemons/com.foo.plist"), home: home),
                       "the helper stops daemons")
        XCTAssertFalse(LaunchJobControl.isAgent(home.appendingPathComponent("Library/LaunchAgents/notes.txt"), home: home))
        XCTAssertFalse(LaunchJobControl.isAgent(home.appendingPathComponent("Library/LaunchAgents/old/com.foo.plist"), home: home))
    }
}
