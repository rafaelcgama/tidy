#if os(macOS)
import Foundation
import TidyCore

// Tidy's privileged helper: a launchd daemon that the app registers with SMAppService. It answers
// only the Tidy app signed by the same team, and it can do five things: say its version, move
// root-owned items into a quarantine only root can change, put a batch back, delete batches of that
// quarantine for good when you ask, and run three fixed maintenance commands. HelperPolicy decides
// what it may touch.

final class HelperService: NSObject, TidyHelperXPC {
    private let service: PrivilegedService

    init(service: PrivilegedService) {
        self.service = service
    }

    func version(reply: @escaping (String) -> Void) {
        // Each check-in also enforces the retention period on the system quarantine.
        _ = try? service.purgeExpired()
        reply(HelperIdentity.version)
    }

    func quarantine(_ request: Data, reply: @escaping (Data?, String?) -> Void) {
        do {
            let decoded = try HelperCoding.decode(HelperQuarantineRequest.self, from: request)
            reply(try HelperCoding.encode(try service.quarantine(decoded)), nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    func restore(batchID: String, reply: @escaping (Data?, String?) -> Void) {
        do {
            reply(try HelperCoding.encode(try service.restore(batchID: batchID)), nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    func runMaintenance(_ task: String, reply: @escaping (String?) -> Void) {
        do {
            try service.runMaintenance(task)
            reply(nil)
        } catch {
            reply(error.localizedDescription)
        }
    }

    func delete(_ request: Data, reply: @escaping (String?) -> Void) {
        do {
            try service.delete(try HelperCoding.decode(HelperDeleteRequest.self, from: request))
            reply(nil)
        } catch {
            reply(error.localizedDescription)
        }
    }
}

/// Exits once no app has been connected for a while. launchd starts the helper again on the next
/// request, so after an update Tidy always talks to its own version of the helper.
final class IdleExit: @unchecked Sendable {
    private let queue = DispatchQueue(label: "TidyHelper.idle")
    private var connections = 0
    private var pending: DispatchWorkItem?

    func opened() {
        queue.async {
            self.connections += 1
            self.pending?.cancel()
            self.pending = nil
        }
    }

    func closed() {
        queue.async {
            self.connections -= 1
            if self.connections <= 0 { self.schedule() }
        }
    }

    func schedule() {
        queue.async {
            self.pending?.cancel()
            let exitNow = DispatchWorkItem { exit(0) }
            self.pending = exitNow
            self.queue.asyncAfter(deadline: .now() + 30, execute: exitNow)
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let requirement: String
    private let exported: HelperService
    private let idle: IdleExit

    init(requirement: String, exported: HelperService, idle: IdleExit) {
        self.requirement = requirement
        self.exported = exported
        self.idle = idle
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // XPC itself drops messages from anything but the Tidy app signed by this team.
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: TidyHelperXPC.self)
        connection.exportedObject = exported
        let idle = self.idle
        idle.opened()
        connection.invalidationHandler = { idle.closed() }
        connection.resume()
        return true
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("TidyHelper: \(message)\n".utf8))
    exit(1)
}

// The helper runs from Tidy.app/Contents/MacOS, so the app around it says who may connect.
let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
let appURL = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
guard appURL.pathExtension == "app", let appID = Bundle(url: appURL)?.bundleIdentifier else {
    fail("not inside Tidy.app")
}
guard let team = CodeSigning.ownTeamID() else {
    fail("not signed with a Developer ID, so it won't run as root")
}

let service = PrivilegedService(policy: HelperPolicy(protectedPaths: [appURL.path]))
_ = try? service.purgeExpired()
let idle = IdleExit()
let delegate = ListenerDelegate(requirement: CodeSigning.requirement(identifier: appID, team: team),
                                exported: HelperService(service: service), idle: idle)
let listener = NSXPCListener(machServiceName: HelperIdentity.machServiceName(appBundleID: appID))
listener.delegate = delegate
listener.resume()
idle.schedule()
dispatchMain()
#else
print("TidyHelper runs only on macOS.")
#endif
