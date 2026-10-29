#if os(macOS)
import Foundation
import Security

/// The privileged helper's whole XPC interface. Payloads are JSON (see HelperCoding), and the
/// helper checks every path in them against HelperPolicy before touching anything.
@objc public protocol TidyHelperXPC {
    func version(reply: @escaping (String) -> Void)
    /// `request` is a HelperQuarantineRequest; the reply is a HelperQuarantineReply or an error message.
    func quarantine(_ request: Data, reply: @escaping (Data?, String?) -> Void)
    /// The reply is a HelperRestoreReply or an error message.
    func restore(batchID: String, reply: @escaping (Data?, String?) -> Void)
    /// `request` is a HelperDeleteRequest; the reply is nil once those batches are deleted for good, or an error message.
    func delete(_ request: Data, reply: @escaping (String?) -> Void)
}

public enum HelperIdentity {
    /// Changes whenever TidyHelperXPC does.
    public static let version = "3"

    /// The helper's launchd label and mach service (Resources/Helper.plist), from the app's bundle id.
    public static func machServiceName(appBundleID: String) -> String {
        appBundleID + ".helper"
    }

    /// Its plist in Tidy.app/Contents/Library/LaunchDaemons, which SMAppService registers.
    public static func plistName(appBundleID: String) -> String {
        machServiceName(appBundleID: appBundleID) + ".plist"
    }
}

/// How the app and its helper recognize each other.
public enum CodeSigning {
    /// The Team ID this process is signed with; nil for ad hoc or unsigned builds.
    public static func ownTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let values = info as? [String: Any] else { return nil }
        return values[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Met only by code signed by this team, through Apple, with this signing identifier.
    public static func requirement(identifier: String, team: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}
#endif
