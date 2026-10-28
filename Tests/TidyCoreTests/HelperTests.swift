import XCTest
@testable import TidyCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The privileged helper's rules, its symlink-proof moves, and the cleaner that splits work between
/// the user's quarantine and the helper's. Everything runs as the test user in a temporary folder.
final class HelperTests: XCTestCase {
    var tmp: URL!
    let fm = FileManager.default
    let me = UInt32(geteuid())

    override func setUpWithError() throws {
        // A path without symlinks in it (on macOS the temporary folder sits behind the /var symlink).
        let base = try XCTUnwrap(SecureFileOps.realPath(fm.temporaryDirectory.path))
        tmp = URL(fileURLWithPath: base).appendingPathComponent("tidy-helper-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tmp)
    }

    @discardableResult
    private func write(_ relative: String, bytes: Int = 100) throws -> URL {
        let url = tmp.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    @discardableResult
    private func folder(_ relative: String) throws -> URL {
        let url = tmp.appendingPathComponent(relative)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A helper whose "system" is tmp/system, with a caches folder and a launch daemons folder.
    private func makeService() throws -> (service: PrivilegedService, system: URL) {
        let system = try folder("system")
        let policy = HelperPolicy(folders: [
            .init(try folder("system/Library/Caches").path),
            .init(try folder("system/Library/LaunchDaemons").path, suffixes: [".plist"], refusedPrefixes: ["com.apple."]),
        ])
        let store = QuarantineStore(root: tmp.appendingPathComponent("helper/Quarantine"), mover: SecureFileOps.mover)
        return (PrivilegedService(policy: policy, store: store, trustedOwner: me, run: { _ in }), system)
    }

    // MARK: - Symlink-proof moves

    func testMoveRefusesASymlinkOnTheWay() throws {
        let file = try write("real/a.txt")
        try folder("dest")
        try fm.createSymbolicLink(at: tmp.appendingPathComponent("link"), withDestinationURL: tmp.appendingPathComponent("real"))
        XCTAssertThrowsError(try SecureFileOps.move(tmp.appendingPathComponent("link/a.txt").path,
                                                    to: tmp.appendingPathComponent("dest/a.txt").path))
        XCTAssertThrowsError(try SecureFileOps.move(file.path, to: tmp.appendingPathComponent("link/b.txt").path), "nor into one")
        XCTAssertTrue(fm.fileExists(atPath: file.path))
    }

    func testMoveNeverReplacesAnything() throws {
        let a = try write("a.txt", bytes: 1)
        let b = try write("b.txt", bytes: 2)
        XCTAssertThrowsError(try SecureFileOps.move(a.path, to: b.path))
        XCTAssertEqual(try Data(contentsOf: b).count, 2)
        XCTAssertTrue(fm.fileExists(atPath: a.path))
    }

    func testMoveMovesFilesAndFolders() throws {
        try write("box/inner/file")
        try folder("dest")
        try SecureFileOps.move(tmp.appendingPathComponent("box").path, to: tmp.appendingPathComponent("dest/box").path)
        XCTAssertTrue(fm.fileExists(atPath: tmp.appendingPathComponent("dest/box/inner/file").path))
        XCTAssertFalse(fm.fileExists(atPath: tmp.appendingPathComponent("box").path))
    }

    func testRelativePathsAndDotsAreRefused() {
        XCTAssertThrowsError(try SecureFileOps.move("relative/a", to: tmp.path + "/b"))
        XCTAssertThrowsError(try SecureFileOps.openDirectory(tmp.path + "/../etc"))
        XCTAssertThrowsError(try SecureFileOps.prepareTrustedFolder(tmp.path + "/./x", owner: me))
    }

    func testTrustedFolderIsCreatedAndChecked() throws {
        let target = tmp.appendingPathComponent("a/b/c").path
        try SecureFileOps.prepareTrustedFolder(target, owner: me)
        XCTAssertEqual(SecureFileOps.entryInfo(target)?.isDirectory, true)
        XCTAssertNoThrow(try SecureFileOps.prepareTrustedFolder(target, owner: me), "an existing folder is fine")

        chmod(tmp.appendingPathComponent("a").path, 0o777)
        XCTAssertThrowsError(try SecureFileOps.prepareTrustedFolder(target, owner: me), "anyone could swap b for a symlink")
        chmod(tmp.appendingPathComponent("a").path, 0o1777)
        XCTAssertNoThrow(try SecureFileOps.prepareTrustedFolder(target, owner: me), "the sticky bit stops that")

        try fm.createSymbolicLink(at: tmp.appendingPathComponent("l"), withDestinationURL: tmp.appendingPathComponent("a"))
        XCTAssertThrowsError(try SecureFileOps.prepareTrustedFolder(tmp.appendingPathComponent("l/b/c").path, owner: me))
    }

    func testTrustedFolderMustBelongToTheOwner() throws {
        try XCTSkipUnless(geteuid() == 0, "needs root to give a folder away")
        let theirs = try folder("theirs")
        XCTAssertEqual(chown(theirs.path, 65534, 65534), 0)
        XCTAssertThrowsError(try SecureFileOps.prepareTrustedFolder(theirs.appendingPathComponent("Quarantine").path, owner: 0))
    }

    // MARK: - Policy

    func testStandardPolicyRules() {
        func ok(_ path: String) -> Bool { HelperPolicy.standard.accepts(URL(fileURLWithPath: path)) }
        XCTAssertTrue(ok("/Library/Caches/com.vendor.cache"))
        XCTAssertFalse(ok("/Library/Caches/.hidden"))
        XCTAssertFalse(ok("/Library/Caches/com.vendor.cache/inner"), "only entries directly in the folder")
        XCTAssertTrue(ok("/private/var/log/system.log.0.gz"))
        XCTAssertFalse(ok("/private/var/log/system.log"), "live logs stay")
        XCTAssertTrue(ok("/Library/LaunchDaemons/com.vendor.helper.plist"))
        XCTAssertFalse(ok("/Library/LaunchDaemons/com.apple.thing.plist"))
        XCTAssertFalse(ok("/Library/LaunchDaemons/README"))
        XCTAssertTrue(ok("/Library/Application Support/Vendor"))
        XCTAssertFalse(ok("/Library/Application Support/Tidy"), "the helper's own quarantine")
        XCTAssertFalse(ok("/Library/Application Support/tidy"))
        XCTAssertFalse(ok("/Library/Application Support/Apple"))
        XCTAssertTrue(ok("/Applications/Vendor.app"))
        XCTAssertFalse(ok("/Applications/Vendor"))
        XCTAssertFalse(ok("/Library/Logs/DiagnosticReports"))
        XCTAssertTrue(ok("/Library/Logs/DiagnosticReports/Vendor-2026-10-28.ips"))
        XCTAssertFalse(ok("/System/Library/Caches/x"))
        XCTAssertFalse(ok("/Library/Keychains/System.keychain"))
        XCTAssertFalse(ok("/Users/someone/Documents/x"))
    }

    func testPolicyChecksTheDiskBeforeAMove() throws {
        let caches = try folder("Caches")
        let app = try write("Caches/Tidy.app/x").deletingLastPathComponent()
        let policy = HelperPolicy(folders: [.init(caches.path)], protectedPaths: [app.path])
        XCTAssertThrowsError(try policy.source(caches.path + "/gone")) { XCTAssertEqual($0 as? HelperPolicy.Refusal, .missing) }
        XCTAssertThrowsError(try policy.source(app.path)) { XCTAssertEqual($0 as? HelperPolicy.Refusal, .protectedItem) }
        XCTAssertThrowsError(try policy.source("Caches/x")) { XCTAssertEqual($0 as? HelperPolicy.Refusal, .notAbsolute) }
        XCTAssertThrowsError(try policy.source(caches.path + "/../Caches/x")) { XCTAssertEqual($0 as? HelperPolicy.Refusal, .notAbsolute) }

        // Swap the folder for a symlink to somewhere else: the path looks right, but the helper refuses.
        try write("elsewhere/secret")
        try fm.moveItem(at: caches, to: tmp.appendingPathComponent("old-caches"))
        try fm.createSymbolicLink(at: caches, withDestinationURL: tmp.appendingPathComponent("elsewhere"))
        XCTAssertThrowsError(try policy.source(caches.path + "/secret")) { XCTAssertEqual($0 as? HelperPolicy.Refusal, .folderNotInPlace) }
    }

    // MARK: - The helper's service

    func testHelperMovesOnlyWhatThePolicyAllowsAndPutsItBack() throws {
        let (service, system) = try makeService()
        let cache = try write("system/Library/Caches/com.foo/blob")
        let daemon = try write("system/Library/LaunchDaemons/com.foo.helper.plist")
        let apple = try write("system/Library/LaunchDaemons/com.apple.thing.plist")
        let elsewhere = try write("system/etc/sudoers")
        let id = QuarantineStore.makeBatchID(Date())
        let reply = try service.quarantine(HelperQuarantineRequest(batchID: id, items: [
            HelperItem(path: cache.deletingLastPathComponent().path, size: 100, category: "System caches"),
            HelperItem(path: daemon.path, size: 100, category: "Launch daemons"),
            HelperItem(path: apple.path, size: 100, category: "Launch daemons"),
            HelperItem(path: elsewhere.path, size: 100, category: "Anything"),
            HelperItem(path: system.path + "/Library/Caches/../../etc/sudoers", size: 1, category: "Sneaky"),
        ]))
        XCTAssertEqual(reply.batch?.id, id)
        XCTAssertEqual(reply.batch?.entries.count, 2)
        XCTAssertEqual(reply.failed.count, 3)
        XCTAssertFalse(fm.fileExists(atPath: cache.path))
        XCTAssertFalse(fm.fileExists(atPath: daemon.path))
        XCTAssertTrue(fm.fileExists(atPath: apple.path))
        XCTAssertTrue(fm.fileExists(atPath: elsewhere.path))

        let restored = try service.restore(batchID: id)
        XCTAssertEqual(restored.restored.count, 2)
        XCTAssertTrue(fm.fileExists(atPath: cache.path))
        XCTAssertTrue(fm.fileExists(atPath: daemon.path))
    }

    func testRestoreRefusesAManifestThatPointsOutsideThePolicy() throws {
        let (service, system) = try makeService()
        let daemon = try write("system/Library/LaunchDaemons/com.foo.helper.plist")
        let id = QuarantineStore.makeBatchID(Date())
        _ = try service.quarantine(HelperQuarantineRequest(batchID: id, items: [HelperItem(path: daemon.path, size: 1, category: "x")]))

        // Rewrite the manifest so the item would land somewhere else.
        let manifest = service.store.root.appendingPathComponent(id).appendingPathComponent("manifest.json")
        var batch = try HelperCoding.decode(QuarantineBatch.self, from: Data(contentsOf: manifest))
        let entry = try XCTUnwrap(batch.entries.first)
        let target = system.appendingPathComponent("etc/evil.plist").path
        batch.entries = [QuarantineEntry(originalPath: target, storedPath: entry.storedPath, size: entry.size, category: entry.category)]
        try HelperCoding.encode(batch).write(to: manifest)

        XCTAssertThrowsError(try service.restore(batchID: id))
        XCTAssertFalse(fm.fileExists(atPath: target))
        XCTAssertTrue(fm.fileExists(atPath: service.store.root.appendingPathComponent(id).appendingPathComponent(entry.storedPath).path))
    }

    func testHelperRefusesBadOrReusedBatchIDs() throws {
        let (service, _) = try makeService()
        let daemon = try write("system/Library/LaunchDaemons/com.foo.helper.plist")
        XCTAssertThrowsError(try service.quarantine(HelperQuarantineRequest(batchID: "../../etc", items: [HelperItem(path: daemon.path, size: 1, category: "x")])))
        XCTAssertTrue(fm.fileExists(atPath: daemon.path))

        let id = QuarantineStore.makeBatchID(Date())
        _ = try service.quarantine(HelperQuarantineRequest(batchID: id, items: [HelperItem(path: daemon.path, size: 1, category: "x")]))
        let other = try write("system/Library/LaunchDaemons/com.foo.other.plist")
        XCTAssertThrowsError(try service.quarantine(HelperQuarantineRequest(batchID: id, items: [HelperItem(path: other.path, size: 1, category: "x")])))
        XCTAssertTrue(fm.fileExists(atPath: other.path))
    }

    func testHelperWontKeepItemsInAFolderOthersCanChange() throws {
        let caches = try folder("system/Library/Caches")
        let cache = try write("system/Library/Caches/com.foo")
        let open = try folder("open")
        chmod(open.path, 0o777)
        let service = PrivilegedService(policy: HelperPolicy(folders: [.init(caches.path)]),
                                        store: QuarantineStore(root: open.appendingPathComponent("Quarantine"), mover: SecureFileOps.mover),
                                        trustedOwner: me, run: { _ in })
        let request = HelperQuarantineRequest(batchID: QuarantineStore.makeBatchID(Date()), items: [HelperItem(path: cache.path, size: 1, category: "x")])
        XCTAssertThrowsError(try service.quarantine(request))
        XCTAssertTrue(fm.fileExists(atPath: cache.path))
    }

    func testMaintenanceRunsOnlyItsFixedCommands() throws {
        final class Recorder: @unchecked Sendable { var commands: [[String]] = [] }
        let recorder = Recorder()
        let service = PrivilegedService(policy: HelperPolicy(folders: []), store: QuarantineStore(root: tmp),
                                        trustedOwner: me, run: { recorder.commands.append($0) })
        try service.runMaintenance("flushDNS")
        XCTAssertEqual(recorder.commands, [["/usr/bin/dscacheutil", "-flushcache"], ["/usr/bin/killall", "-HUP", "mDNSResponder"]])
        XCTAssertThrowsError(try service.runMaintenance("rm -rf /"))
        XCTAssertEqual(recorder.commands.count, 2)
    }

    func testRepliesSurviveTheTripOverXPC() throws {
        let entry = QuarantineEntry(originalPath: "/Library/Caches/x", storedPath: "items/0/x", size: 5, category: "System caches")
        let reply = HelperQuarantineReply(batch: QuarantineBatch(id: "20261028-101500-1A2B3C4D", date: Date(), entries: [entry]),
                                          failed: [HelperFailure(path: "/etc/passwd", reason: "no")])
        let decoded = try HelperCoding.decode(HelperQuarantineReply.self, from: HelperCoding.encode(reply))
        XCTAssertEqual(decoded.batch?.entries, [entry])
        XCTAssertEqual(decoded.failed, reply.failed)
    }

    // MARK: - Splitting a clean between the user and the helper

    func testCleanSplitsBetweenTheUserAndTheHelperUnderOneBatch() async throws {
        let (service, system) = try makeService()
        let userCache = try write("home/Library/Caches/com.foo/blob")
        let systemCache = try write("system/Library/Caches/com.foo/blob")
        let userStore = QuarantineStore(root: tmp.appendingPathComponent("home/Quarantine"))
        let safe = SafePaths(allowedRoots: [tmp.appendingPathComponent("home/Library/Caches"), system.appendingPathComponent("Library/Caches")])
        let systemPath = system.path
        let link = AdminAwareCleaner.HelperLink(quarantine: { try service.quarantine($0) },
                                                restore: { try service.restore(batchID: $0) },
                                                delete: { _ = try service.delete(HelperDeleteRequest(batchIDs: $0)) })
        let cleaner = AdminAwareCleaner(user: QuarantineCleaner(store: userStore, safePaths: safe), systemStore: service.store,
                                        needsAdmin: { $0.path.hasPrefix(systemPath) }, helper: link)
        let items = [userCache, systemCache].map {
            ScanItem(url: $0.deletingLastPathComponent(), size: 100, category: "Caches", isSelected: true)
        }

        let plan = try await cleaner.clean(items, dryRun: true)
        XCTAssertEqual(plan.removed.count, 2)
        XCTAssertTrue(fm.fileExists(atPath: systemCache.path), "a dry run changes nothing")

        let result = try await cleaner.clean(items, dryRun: false)
        XCTAssertEqual(result.removed.count, 2)
        XCTAssertTrue(result.skipped.isEmpty)
        let batch = try XCTUnwrap(result.batch)
        XCTAssertEqual(batch.entries.count, 2)
        XCTAssertTrue(userStore.hasBatch(batch.id))
        XCTAssertTrue(service.store.hasBatch(batch.id), "both halves carry the same id")
        XCTAssertFalse(fm.fileExists(atPath: userCache.path))
        XCTAssertFalse(fm.fileExists(atPath: systemCache.path))
        XCTAssertEqual(cleaner.batches().map(\.id), [batch.id], "listed once")
        XCTAssertEqual(cleaner.batches().first?.entries.count, 2)

        let undone = try await cleaner.undo(batchID: batch.id)
        XCTAssertEqual(undone.restored.count, 2)
        XCTAssertTrue(fm.fileExists(atPath: userCache.path))
        XCTAssertTrue(fm.fileExists(atPath: systemCache.path))
    }

    func testWithoutTheHelperRootOwnedItemsAreSkippedWithTheReason() async throws {
        let userCache = try write("home/Library/Caches/a/blob").deletingLastPathComponent()
        let systemCache = try write("system/Library/Caches/b/blob").deletingLastPathComponent()
        let systemPath = tmp.appendingPathComponent("system").path
        let cleaner = AdminAwareCleaner(user: QuarantineCleaner(store: QuarantineStore(root: tmp.appendingPathComponent("q")),
                                                                safePaths: SafePaths(allowedRoots: [tmp])),
                                        systemStore: QuarantineStore(root: tmp.appendingPathComponent("none")),
                                        needsAdmin: { $0.path.hasPrefix(systemPath) }, helper: nil)
        let items = [userCache, systemCache].map { ScanItem(url: $0, size: 100, category: "Caches", isSelected: true) }
        let result = try await cleaner.clean(items, dryRun: false)
        XCTAssertEqual(result.removed.map(\.url), [userCache])
        XCTAssertEqual(result.skipped.map { $0.reason }, [AdminAwareCleaner.helperMissing])
        XCTAssertTrue(fm.fileExists(atPath: systemCache.path))
    }

    func testYourAgentsStopBeforeTheyMoveAndStartWhenPutBack() async throws {
        let agent = try write("home/Library/LaunchAgents/com.foo.agent.plist")
        let calls = Recorder<String>()
        let cleaner = AdminAwareCleaner(user: QuarantineCleaner(store: QuarantineStore(root: tmp.appendingPathComponent("q")),
                                                                safePaths: SafePaths(allowedRoots: [tmp])),
                                        systemStore: QuarantineStore(root: tmp.appendingPathComponent("none")),
                                        needsAdmin: { _ in false }, helper: nil,
                                        changeAgent: { url, start in calls.add((start ? "start " : "stop ") + url.path) })
        let items = [ScanItem(url: agent, size: 100, category: "Launch agents", isSelected: true)]
        _ = try await cleaner.clean(items, dryRun: true)
        XCTAssertTrue(calls.all.isEmpty, "a dry run changes nothing")

        let result = try await cleaner.clean(items, dryRun: false)
        XCTAssertEqual(calls.all, ["stop " + agent.path])
        XCTAssertFalse(fm.fileExists(atPath: agent.path))
        _ = try await cleaner.undo(batchID: try XCTUnwrap(result.batch).id)
        XCTAssertEqual(calls.all, ["stop " + agent.path, "start " + agent.path])
    }

    func testAgentsThatBelongToRootStopAndStartToo() async throws {
        let (service, system) = try makeService()
        try folder("system/Library/LaunchAgents")
        let policy = HelperPolicy(folders: [.init(system.appendingPathComponent("Library/LaunchAgents").path, suffixes: [".plist"])])
        let helper = PrivilegedService(policy: policy, store: service.store, trustedOwner: me, run: { _ in })
        let agent = try write("system/Library/LaunchAgents/com.foo.agent.plist")
        let systemPath = system.path
        let calls = Recorder<String>()
        func cleaner(_ quarantine: @escaping @Sendable (HelperQuarantineRequest) async throws -> HelperQuarantineReply) -> AdminAwareCleaner {
            AdminAwareCleaner(user: QuarantineCleaner(store: QuarantineStore(root: tmp.appendingPathComponent("q")),
                                                      safePaths: SafePaths(allowedRoots: [tmp])),
                              systemStore: helper.store, needsAdmin: { $0.path.hasPrefix(systemPath) },
                              helper: AdminAwareCleaner.HelperLink(quarantine: quarantine, restore: { try helper.restore(batchID: $0) },
                                                                   delete: { _ = try helper.delete(HelperDeleteRequest(batchIDs: $0)) }),
                              changeAgent: { url, start in calls.add((start ? "start " : "stop ") + url.lastPathComponent) })
        }
        let items = [ScanItem(url: agent, size: 100, category: "Launch agents", isSelected: true)]

        _ = try await cleaner { _ in throw AdminPrompt.Failure.cancelled }.clean(items, dryRun: false)
        XCTAssertEqual(calls.all, ["stop com.foo.agent.plist", "start com.foo.agent.plist"], "started again when it didn't move")
        XCTAssertTrue(fm.fileExists(atPath: agent.path))

        let working = cleaner { try helper.quarantine($0) }
        let result = try await working.clean(items, dryRun: false)
        XCTAssertFalse(fm.fileExists(atPath: agent.path))
        XCTAssertEqual(calls.all.last, "stop com.foo.agent.plist")
        _ = try await working.undo(batchID: try XCTUnwrap(result.batch).id)
        XCTAssertTrue(fm.fileExists(atPath: agent.path))
        XCTAssertEqual(calls.all.last, "start com.foo.agent.plist")
    }

    func testHelperStopsADaemonItMovesAndStartsItWhenPutBack() throws {
        let policy = HelperPolicy(folders: [.init(try folder("system/Library/LaunchDaemons").path, suffixes: [".plist"])])
        let commands = Recorder<[String]>()
        let service = PrivilegedService(policy: policy, store: QuarantineStore(root: tmp.appendingPathComponent("helper/Quarantine"),
                                                                                mover: SecureFileOps.mover),
                                        trustedOwner: me, run: { commands.add($0) })
        let plist = try write("system/Library/LaunchDaemons/com.foo.daemon.plist")
        let batchID = QuarantineStore.makeBatchID(Date())
        _ = try service.quarantine(HelperQuarantineRequest(batchID: batchID, items: [HelperItem(path: plist.path, size: 100, category: "Launch daemons")]))
        XCTAssertEqual(commands.all, [["/bin/launchctl", "bootout", "system", plist.path]])
        XCTAssertFalse(fm.fileExists(atPath: plist.path))

        _ = try service.restore(batchID: batchID)
        XCTAssertEqual(commands.all.last, ["/bin/launchctl", "bootstrap", "system", plist.path])
        XCTAssertTrue(fm.fileExists(atPath: plist.path))
    }

    // MARK: - Deleting for good

    func testHelperDeletesSystemBatchesOnlyWhenEveryOneIsThere() throws {
        let (service, _) = try makeService()
        let first = try write("system/Library/Caches/a/blob").deletingLastPathComponent()
        let second = try write("system/Library/Caches/b/blob").deletingLastPathComponent()
        let one = QuarantineStore.makeBatchID(Date())
        let two = QuarantineStore.makeBatchID(Date())
        _ = try service.quarantine(HelperQuarantineRequest(batchID: one, items: [HelperItem(path: first.path, size: 100, category: "Caches")]))
        _ = try service.quarantine(HelperQuarantineRequest(batchID: two, items: [HelperItem(path: second.path, size: 100, category: "Caches")]))

        XCTAssertThrowsError(try service.delete(HelperDeleteRequest(batchIDs: [one, QuarantineStore.makeBatchID(Date())])))
        XCTAssertThrowsError(try service.delete(HelperDeleteRequest(batchIDs: [one, "../../etc"])))
        XCTAssertEqual(Set(service.store.batches().map(\.id)), [one, two], "nothing deleted")

        XCTAssertEqual(try service.delete(HelperDeleteRequest(batchIDs: [one, one])).map(\.id), [one])
        XCTAssertEqual(service.store.batches().map(\.id), [two])
        XCTAssertFalse(fm.fileExists(atPath: first.path))
        XCTAssertTrue(try service.delete(HelperDeleteRequest(batchIDs: [])).isEmpty)
    }

    func testDeletingASplitBatchTakesBothHalvesOrNothing() async throws {
        let (service, system) = try makeService()
        let userCache = try write("home/Library/Caches/com.foo/blob").deletingLastPathComponent()
        let ownCache = try write("home/Library/Caches/com.bar/blob").deletingLastPathComponent()
        let systemCache = try write("system/Library/Caches/com.foo/blob").deletingLastPathComponent()
        let userStore = QuarantineStore(root: tmp.appendingPathComponent("home/Quarantine"))
        let safe = SafePaths(allowedRoots: [tmp.appendingPathComponent("home/Library/Caches"), system.appendingPathComponent("Library/Caches")])
        let systemPath = system.path
        func cleaner(_ helper: AdminAwareCleaner.HelperLink?) -> AdminAwareCleaner {
            AdminAwareCleaner(user: QuarantineCleaner(store: userStore, safePaths: safe), systemStore: service.store,
                              needsAdmin: { $0.path.hasPrefix(systemPath) }, helper: helper)
        }
        func link(_ delete: @escaping @Sendable ([String]) async throws -> Void) -> AdminAwareCleaner.HelperLink {
            AdminAwareCleaner.HelperLink(quarantine: { try service.quarantine($0) }, restore: { try service.restore(batchID: $0) }, delete: delete)
        }
        let working = cleaner(link { _ = try service.delete(HelperDeleteRequest(batchIDs: $0)) })
        let splitClean = try await working.clean([userCache, systemCache].map {
            ScanItem(url: $0, size: 100, category: "Caches", isSelected: true)
        }, dryRun: false)
        let split = try XCTUnwrap(splitClean.batch)
        let ownClean = try await working.clean([ScanItem(url: ownCache, size: 100, category: "Caches", isSelected: true)], dryRun: false)
        let own = try XCTUnwrap(ownClean.batch)

        do {
            try await cleaner(link { _ in throw AdminPrompt.Failure.cancelled }).delete(batchIDs: [split.id])
            XCTFail("the password prompt was cancelled")
        } catch {
            XCTAssertEqual(error as? AdminPrompt.Failure, .cancelled)
        }
        XCTAssertTrue(userStore.hasBatch(split.id), "nothing deleted")
        XCTAssertTrue(service.store.hasBatch(split.id))

        do {
            try await cleaner(nil).delete(batchIDs: [split.id])
            XCTFail("part of it belongs to the system")
        } catch {
            XCTAssertTrue(error is AdminAwareCleaner.NeedsAdmin)
        }
        XCTAssertTrue(userStore.hasBatch(split.id))
        try await cleaner(nil).delete(batchIDs: [own.id])
        XCTAssertFalse(userStore.hasBatch(own.id), "your own batch needs no root")

        let deleted = try await working.delete(batchIDs: [split.id])
        XCTAssertEqual(deleted.map(\.id), [split.id])
        XCTAssertEqual(deleted.first?.entries.count, 2, "both halves")
        XCTAssertFalse(userStore.hasBatch(split.id))
        XCTAssertFalse(service.store.hasBatch(split.id))
        XCTAssertTrue(working.batches().isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: userCache.path))
        XCTAssertFalse(fm.fileExists(atPath: systemCache.path))
        do {
            try await working.delete(batchIDs: [split.id])
            XCTFail("already gone")
        } catch {}
    }

    func testYourOwnFilesDontNeedAdmin() throws {
        XCTAssertFalse(AdminAccess.needsAdmin(try write("mine.txt")))
        XCTAssertFalse(AdminAccess.needsAdmin(try folder("my-folder")))
        if geteuid() != 0 {
            XCTAssertTrue(AdminAccess.needsAdmin(URL(fileURLWithPath: "/usr/bin/true")))
        }
    }

    // MARK: - Leftovers in /Library

    func testSystemLibraryLeftoversIncludeDaemonsAndHelperTools() throws {
        let library = try folder("SystemLibrary")
        try write("SystemLibrary/LaunchDaemons/com.foo.app.helper.plist")
        try write("SystemLibrary/PrivilegedHelperTools/com.foo.app.helper")
        try write("SystemLibrary/LaunchDaemons/com.other.app.plist")
        let items = LeftoverFinder(library: library).leftovers(bundleID: "com.foo.app", appName: "Foo", installedBundleIDs: ["com.other.app"])
        XCTAssertEqual(Set(items.map(\.category)), ["Launch daemons", "Helper tools"])
        XCTAssertTrue(items.allSatisfy(\.isSelected))
    }
}

/// Collects what a closure was called with, from any thread.
final class Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func add(_ value: Value) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var all: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
