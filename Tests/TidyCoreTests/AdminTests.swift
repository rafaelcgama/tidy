import XCTest
@testable import TidyCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// What Tidy does as root without the admin helper (the password prompt, and Tidy run as root for one
/// request), and switching login items. Stand-in osascript scripts take the place of macOS's.
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

    // MARK: - Launch jobs

    private func job(_ label: String, scope: LaunchItem.Scope = .userAgent, disabled: Bool = false) -> LaunchItem {
        LaunchItem(url: tmp.appendingPathComponent("LaunchAgents/\(label).plist"), label: label, program: "/bin/true",
                   arguments: [], runAtLoad: true, keepAlive: false, disabled: disabled, scope: scope)
    }

    func testReadsLaunchdsSwitches() {
        let output = """
            disabled services = {
            \t"com.apple.ftp-proxy" => disabled
            \t"com.foo.agent" => enabled
            \t"com.bar.old" => true
            \t"com.bar.new" => false
            }

            login item associations = {
            \t"com.foo.agent" => disabled
            }
            """
        XCTAssertEqual(LaunchJobControl.parseSwitches(output),
                       ["com.apple.ftp-proxy": true, "com.foo.agent": false, "com.bar.old": true, "com.bar.new": false])
    }

    func testLaunchdsSwitchWinsOverThePlist() {
        XCTAssertFalse(LaunchJobControl.isOn(job("com.foo.agent", disabled: true), switches: [:]))
        XCTAssertTrue(LaunchJobControl.isOn(job("com.foo.agent", disabled: true), switches: ["com.foo.agent": false]))
        XCTAssertFalse(LaunchJobControl.isOn(job("com.foo.agent"), switches: ["com.foo.agent": true]))
        XCTAssertTrue(LaunchJobControl.isOn(job("com.foo.agent"), switches: ["com.other": true]))
    }

    func testSwitchingAgentsAndDaemons() throws {
        let agent = job("com.foo.agent")
        XCTAssertEqual(try LaunchJobControl.steps(for: agent, on: true, uid: 501), [
            AdminPrompt.Step(["/bin/launchctl", "enable", "gui/501/com.foo.agent"]),
            AdminPrompt.Step(["/bin/launchctl", "bootstrap", "gui/501", agent.url.path], mayFail: true),
        ])
        let daemon = job("com.foo.daemon", scope: .daemon)
        XCTAssertEqual(try LaunchJobControl.steps(for: daemon, on: false, uid: 501), [
            AdminPrompt.Step(["/bin/launchctl", "disable", "system/com.foo.daemon"]),
            AdminPrompt.Step(["/bin/launchctl", "bootout", "system/com.foo.daemon"], mayFail: true),
        ])
        XCTAssertTrue(LaunchJobControl.needsAdmin(daemon))
        XCTAssertFalse(LaunchJobControl.needsAdmin(agent))
        XCTAssertEqual(LaunchJobControl.domain(for: .globalAgent, uid: 501), "gui/501")
        XCTAssertThrowsError(try LaunchJobControl.steps(for: job("bad; rm -rf ~"), on: false, uid: 501))
    }

    func testLabelsTidyPassesToLaunchctl() {
        XCTAssertTrue(LaunchJobControl.isUsableLabel("com.foo.agent"))
        XCTAssertTrue(LaunchJobControl.isUsableLabel("application.com.foo.123_45@x+y-z"))
        XCTAssertFalse(LaunchJobControl.isUsableLabel(""))
        XCTAssertFalse(LaunchJobControl.isUsableLabel("-h"))
        XCTAssertFalse(LaunchJobControl.isUsableLabel("a b"))
        XCTAssertFalse(LaunchJobControl.isUsableLabel("a/b"))
        XCTAssertFalse(LaunchJobControl.isUsableLabel(String(repeating: "a", count: 256)))
    }

    func testOnlyAgentsAreStoppedAndStartedInYourSession() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertTrue(LaunchJobControl.isAgent(home.appendingPathComponent("Library/LaunchAgents/com.foo.plist"), home: home))
        XCTAssertTrue(LaunchJobControl.isAgent(URL(fileURLWithPath: "/Library/LaunchAgents/com.foo.plist"), home: home))
        XCTAssertFalse(LaunchJobControl.isAgent(URL(fileURLWithPath: "/Library/LaunchDaemons/com.foo.plist"), home: home),
                       "the helper stops daemons")
        XCTAssertFalse(LaunchJobControl.isAgent(home.appendingPathComponent("Library/LaunchAgents/notes.txt"), home: home))
        XCTAssertFalse(LaunchJobControl.isAgent(home.appendingPathComponent("Library/LaunchAgents/old/com.foo.plist"), home: home))
    }

    // MARK: - Apps that open at login

    /// Answers like System Events: the list from list.txt, or "not allowed" while a file named deny exists.
    private static let fakeSystemEvents = """
        dir=$(dirname "$0")
        for arg in "$@"; do printf '%s\\n' "$arg" >> "$dir/calls.log"; done
        echo "--" >> "$dir/calls.log"
        if [ -f "$dir/deny" ]; then
            echo "0:0: execution error: Not authorized to send Apple events to System Events. (-1743)" >&2
            exit 1
        fi
        case "$*" in *"repeat with loginItem"*) cat "$dir/list.txt";; esac
        exit 0
        """

    /// The arguments of each osascript run so far.
    private func calls() throws -> [[String]] {
        let log = try String(contentsOf: tmp.appendingPathComponent("calls.log"), encoding: .utf8)
        return log.components(separatedBy: "--\n").filter { !$0.isEmpty }.map { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).dropLast() }
    }

    func testListsTurnsOffAndTurnsBackOnAppsThatOpenAtLogin() throws {
        let osascript = try script("osascript", Self.fakeSystemEvents)
        let dropbox = try folder("Apps/Dropbox.app")
        let notes = try folder("Apps/Notes.app")
        try write("list.txt", "Dropbox\n\(dropbox.path)\nfalse\nNotes\n\(notes.path)\ntrue\n")
        let apps = LoginApps(storeURL: tmp.appendingPathComponent("store/turned-off.json"), osascript: osascript)

        let listed = try apps.list()
        XCTAssertEqual(listed.on, [LoginApp(name: "Dropbox", path: dropbox.path, hidden: false),
                                   LoginApp(name: "Notes", path: notes.path, hidden: true)])
        XCTAssertTrue(listed.off.isEmpty)

        try apps.turnOff(listed.on[0])
        let off = try XCTUnwrap(try calls().last)
        XCTAssertTrue(off.contains { $0.contains("delete (every login item whose path is (item 1 of argv))") })
        XCTAssertEqual(off.last, dropbox.path, "the path arrives as data")
        try write("list.txt", "Notes\n\(notes.path)\ntrue\n")
        XCTAssertEqual(try apps.list().off.map(\.name), ["Dropbox"], "remembered, so it can go back on")

        try apps.turnOn(LoginApp(name: "Dropbox", path: dropbox.path, hidden: false))
        let on = try XCTUnwrap(try calls().last)
        XCTAssertTrue(on.contains { $0.contains("make login item at end") })
        XCTAssertEqual(Array(on.suffix(2)), [dropbox.path, "false"])
        XCTAssertTrue(try apps.list().off.isEmpty)
    }

    func testForgetsTurnedOffAppsThatAreGone() throws {
        let osascript = try script("osascript", Self.fakeSystemEvents)
        try write("list.txt", "")
        let apps = LoginApps(storeURL: tmp.appendingPathComponent("store/turned-off.json"), osascript: osascript)
        try apps.turnOff(LoginApp(name: "Gone", path: tmp.appendingPathComponent("Apps/Gone.app").path, hidden: false))
        XCTAssertTrue(try apps.list().off.isEmpty)
    }

    func testSaysWhenMacOSDoesntLetTidyAskSystemEvents() throws {
        let osascript = try script("osascript", Self.fakeSystemEvents)
        try write("deny", "")
        let apps = LoginApps(storeURL: tmp.appendingPathComponent("store/turned-off.json"), osascript: osascript)
        XCTAssertThrowsError(try apps.list()) { XCTAssertEqual($0 as? LoginApps.Failure, .notAllowed) }
    }

    func testParsesLoginItems() {
        let parsed = LoginApps.parse("\n/Applications/A.app\nfalse\nweird\nnot-a-path\ntrue\nB\n/Applications/B.app\n")
        XCTAssertEqual(parsed, [LoginApp(name: "A", path: "/Applications/A.app", hidden: false)])
    }
}
