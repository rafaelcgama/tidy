import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The admin helper's work, done by Tidy itself run as root for one request after macOS asks for an
/// administrator's password. It's how builds that can't install the helper (running from Xcode, or
/// a Tidy.app signed ad hoc) still move items that belong to the system, and put them back. It's the
/// helper's own service with the helper's policy, and it takes no other requests.
public enum AdminCommand {
    /// The argument, right after the program, that starts Tidy this way.
    public static let flag = "--tidy-admin"

    public enum Request: Codable, Sendable {
        case quarantine(HelperQuarantineRequest)
        case restore(batchID: String)
        case delete(HelperDeleteRequest)
    }

    /// What follows the program: the flag, then the request as JSON in one argument.
    public static func arguments(for request: Request) throws -> [String] {
        [flag, String(decoding: try HelperCoding.encode(request), as: UTF8.self)]
    }

    /// Handles the process's arguments (program first) when they ask for this: returns what to print
    /// and the exit status. Nil means Tidy starts as usual.
    public static func handle(_ arguments: [String], service: PrivilegedService,
                              isRoot: Bool = geteuid() == 0) -> (output: String, status: Int32)? {
        guard arguments.count > 1, arguments[1] == flag else { return nil }
        guard arguments.count == 3 else { return ("Usage: \(flag) <request>", 64) }
        guard isRoot else { return ("This needs to run as root.", 77) }
        do {
            let request = try HelperCoding.decode(Request.self, from: Data(arguments[2].utf8))
            let reply: Data
            switch request {
            case .quarantine(let quarantine):
                reply = try HelperCoding.encode(try service.quarantine(quarantine))
            case .restore(let batchID):
                reply = try HelperCoding.encode(try service.restore(batchID: batchID))
            case .delete(let delete):
                reply = try HelperCoding.encode(try service.delete(delete))
            }
            // Each run also enforces the retention period, as the helper does when the app checks in.
            _ = try? service.purgeExpired()
            return (String(decoding: reply, as: UTF8.self), 0)
        } catch {
            return (error.localizedDescription, 1)
        }
    }

    /// Reads the reply a root run printed.
    public static func reply<T: Decodable>(_ type: T.Type, from output: String) throws -> T {
        try HelperCoding.decode(type, from: Data(output.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    }
}
