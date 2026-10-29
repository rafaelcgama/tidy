import Foundation
#if canImport(Security)
import Security
#endif

/// What a program's code signature says about who made it.
public enum CodeSignature: Sendable, Equatable {
    /// Signed by Apple, or by a developer Apple identified (Developer ID or the App Store).
    case identified
    /// Signed, but not with a certificate from Apple: ad hoc, as code built on this Mac is, or self-signed.
    case notIdentified
    case unsigned
    /// Changed after it was signed.
    case broken
    /// Couldn't be checked.
    case unknown

    /// Checks the program itself, not every file of the app it's in, which takes long for big apps.
    public static func check(_ path: String) -> CodeSignature {
        #if canImport(Security)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return .unknown }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess else { return .unknown }
        switch Int(SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: UInt32(kSecCSDoNotValidateResources)), requirement)) {
        case Int(errSecSuccess): return .identified
        case Int(errSecCSReqFailed): return .notIdentified
        case Int(errSecCSUnsigned): return .unsigned
        case Int(errSecCSSignatureFailed), Int(errSecCSSignatureInvalid): return .broken
        default: return .unknown
        }
        #else
        return .unknown
        #endif
    }
}
