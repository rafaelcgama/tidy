import AppKit
import Combine
import ServiceManagement
import TidyCore

/// Tidy's privileged helper, from the app's side: installing it with SMAppService and calling it over XPC.
/// Without it (running from Xcode, or a Tidy.app not signed with a Developer ID), the same work runs
/// after macOS asks for an administrator's password, once for each action.
@MainActor
final class AdminHelper: ObservableObject {
    static let shared = AdminHelper()

    enum Status: Equatable {
        /// This build can't use the helper: it isn't a Developer ID–signed Tidy.app.
        case unavailable
        case notInstalled
        /// Registered, but macOS waits for the user to allow it in Login Items.
        case needsApproval
        case enabled
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @Published private(set) var status: Status = .unavailable
    @Published var errorMessage: String?

    private let service: SMAppService?
    private let machServiceName: String?
    /// What the helper's signature must meet, so Tidy never sends paths to an impostor.
    private let helperRequirement: String?

    private init() {
        if Bundle.main.bundleURL.pathExtension == "app",
           let appID = Bundle.main.bundleIdentifier,
           let team = CodeSigning.ownTeamID() {
            let name = HelperIdentity.machServiceName(appBundleID: appID)
            service = SMAppService.daemon(plistName: HelperIdentity.plistName(appBundleID: appID))
            machServiceName = name
            helperRequirement = CodeSigning.requirement(identifier: name, team: team)
        } else {
            service = nil
            machServiceName = nil
            helperRequirement = nil
        }
        refresh()
    }

    var isEnabled: Bool { status == .enabled }

    var statusText: String {
        switch status {
        case .unavailable: return "Needs a Developer ID–signed Tidy.app (see the README). Until then, macOS asks for your password"
        case .notInstalled: return "Not installed"
        case .needsApproval: return "Waiting for your OK in System Settings → General → Login Items"
        case .enabled: return "Installed"
        }
    }

    /// The helper's calls, for AdminAwareCleaner, once it's installed and allowed. Until then, Tidy
    /// itself does the same work as root, after macOS asks for an administrator's password.
    var link: AdminAwareCleaner.HelperLink? {
        guard isEnabled else { return Self.passwordLink }
        return AdminAwareCleaner.HelperLink(quarantine: { [self] request in try await self.quarantine(request) },
                                            restore: { [self] batchID in try await self.restore(batchID: batchID) },
                                            delete: { [self] batchIDs in try await self.delete(batchIDs: batchIDs) })
    }

    /// Tidy's own program run as root for one request (see AdminCommand), with the helper's rules.
    nonisolated static var passwordLink: AdminAwareCleaner.HelperLink? {
        guard let program = Bundle.main.executableURL?.path else { return nil }
        return AdminAwareCleaner.HelperLink(
            quarantine: { request in
                try await AdminHelper.runAsRoot(program, .quarantine(request), reply: HelperQuarantineReply.self,
                                                prompt: "Tidy needs an administrator's password to move items that belong to the system to quarantine.")
            },
            restore: { batchID in
                try await AdminHelper.runAsRoot(program, .restore(batchID: batchID), reply: HelperRestoreReply.self,
                                                prompt: "Tidy needs an administrator's password to put back items that belong to the system.")
            },
            delete: { batchIDs in
                _ = try await AdminHelper.runAsRoot(program, .delete(HelperDeleteRequest(batchIDs: batchIDs)), reply: [QuarantineBatch].self,
                                                    prompt: "Tidy needs an administrator's password to delete items that belong to the system for good.")
            })
    }

    private nonisolated static func runAsRoot<Reply: Decodable>(_ program: String, _ request: AdminCommand.Request,
                                                                reply: Reply.Type, prompt: String) async throws -> Reply {
        let command = [program] + (try AdminCommand.arguments(for: request))
        // Each word goes through osascript and the shell as one argument, which macOS caps at about 1 MB.
        guard command.reduce(0, { $0 + $1.utf8.count }) < 500_000 else {
            throw Failure(message: "That's too many items that belong to the system for one password prompt. Choose fewer at a time.")
        }
        return try AdminCommand.reply(reply, from: try await AdminHelper.runAsRoot([AdminPrompt.Step(command)], prompt: prompt))
    }

    /// Runs fixed commands as root after macOS asks for an administrator's password, away from the main thread.
    nonisolated static func runAsRoot(_ steps: [AdminPrompt.Step], prompt: String) async throws -> String {
        try await Task.detached { try AdminPrompt().run(steps, prompt: prompt) }.value
    }

    func refresh() {
        guard let service else {
            status = .unavailable
            return
        }
        switch service.status {
        case .enabled: status = .enabled
        case .requiresApproval: status = .needsApproval
        default: status = .notInstalled
        }
    }

    func install() {
        guard let service else { return }
        errorMessage = nil
        do {
            try service.register()
        } catch {
            errorMessage = "macOS didn't install the helper: \(error.localizedDescription)"
        }
        refresh()
        if status == .needsApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func uninstall() {
        guard let service else { return }
        errorMessage = nil
        do {
            try service.unregister()
        } catch {
            errorMessage = "macOS didn't remove the helper: \(error.localizedDescription)"
        }
        refresh()
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// At launch: a quick call lets the helper delete system quarantine batches past the retention period.
    func checkIn() {
        refresh()
        guard isEnabled else { return }
        Task {
            let _: String? = try? await call { helper, done in helper.version { done(.success($0)) } }
        }
    }

    func quarantine(_ request: HelperQuarantineRequest) async throws -> HelperQuarantineReply {
        let payload = try HelperCoding.encode(request)
        let data: Data = try await call { helper, done in
            helper.quarantine(payload) { data, error in done(Self.result(data, error)) }
        }
        return try HelperCoding.decode(HelperQuarantineReply.self, from: data)
    }

    func restore(batchID: String) async throws -> HelperRestoreReply {
        let data: Data = try await call { helper, done in
            helper.restore(batchID: batchID) { data, error in done(Self.result(data, error)) }
        }
        return try HelperCoding.decode(HelperRestoreReply.self, from: data)
    }

    func delete(batchIDs: [String]) async throws {
        let payload = try HelperCoding.encode(HelperDeleteRequest(batchIDs: batchIDs))
        let failure: String? = try await call { helper, done in
            helper.delete(payload) { done(.success($0)) }
        }
        if let failure { throw Failure(message: failure) }
    }

    private nonisolated static func result(_ data: Data?, _ error: String?) -> Result<Data, Error> {
        if let data { return .success(data) }
        return .failure(Failure(message: error ?? "Tidy's helper didn't answer."))
    }

    /// One call on a fresh connection. The helper checks this is really Tidy, and Tidy checks it's really the helper.
    private func call<T>(_ body: @escaping (TidyHelperXPC, @escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        guard isEnabled, let machServiceName, let helperRequirement else {
            throw Failure(message: "Tidy's admin helper isn't installed. Install it in Settings → Admin Helper.")
        }
        let connection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: TidyHelperXPC.self)
        connection.setCodeSigningRequirement(helperRequirement)
        connection.resume()
        defer { connection.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in once.resume(with: .failure(error)) }
            guard let helper = proxy as? TidyHelperXPC else {
                once.resume(with: .failure(Failure(message: "Tidy's helper answered with an unexpected interface.")))
                return
            }
            body(helper) { once.resume(with: $0) }
        }
    }
}

/// Resumes a continuation only once: XPC can report an error as well as a reply.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

extension AdminAwareCleaner {
    /// The cleaner every screen uses: your own quarantine, plus the admin helper for root-owned items
    /// (or, until it's installed, the password prompt).
    @MainActor
    static func forApp(store: QuarantineStore, safePaths: SafePaths) -> AdminAwareCleaner {
        AdminAwareCleaner(user: QuarantineCleaner(store: store, safePaths: safePaths), helper: AdminHelper.shared.link)
    }
}
