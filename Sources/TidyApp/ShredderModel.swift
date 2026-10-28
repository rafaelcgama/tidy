import AppKit
import TidyCore

/// The shredder: what you hand it, what that would destroy, a typed confirmation, then overwrite and delete.
@MainActor
final class ShredderModel: ObservableObject {
    enum Phase {
        case choosing
        case shredding(done: Int64, total: Int64)
        case done(Shredder.Result)
    }

    /// Typed before anything is shredded.
    static let confirmationWord = "shred"

    @Published private(set) var phase: Phase = .choosing
    @Published private(set) var chosen: [URL] = []
    /// What shredding `chosen` would destroy; nil while it's being worked out.
    @Published private(set) var plan: Shredder.Plan?
    @Published var confirmation = ""
    /// Whether FileVault encrypts the startup disk; nil until known.
    @Published private(set) var fileVaultOn: Bool?
    @Published var errorMessage: String?

    let shredder = Shredder()
    private var planTask: Task<Void, Never>?

    var canShred: Bool {
        guard case .choosing = phase, let plan, !plan.accepted.isEmpty else { return false }
        return confirmation.trimmingCharacters(in: .whitespaces).lowercased() == Self.confirmationWord
    }

    func refusal(for url: URL) -> String? {
        plan?.refused.first { $0.url.path == url.path }?.reason
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose the files or folders to shred. Nothing happens until you confirm."
        if panel.runModal() == .OK {
            add(panel.urls)
        }
    }

    func add(_ urls: [URL]) {
        guard case .choosing = phase else { return }
        let known = Set(chosen.map(\.path))
        chosen += urls.filter { !known.contains($0.path) }
        replan()
    }

    func remove(_ url: URL) {
        chosen.removeAll { $0.path == url.path }
        replan()
    }

    func clear() {
        chosen = []
        confirmation = ""
        replan()
    }

    /// Big folders take a moment to count, so that happens off the main thread.
    private func replan() {
        planTask?.cancel()
        plan = nil
        guard !chosen.isEmpty else { return }
        let items = chosen
        let shredder = self.shredder
        planTask = Task {
            let plan = await Task.detached { shredder.plan(items) }.value
            if !Task.isCancelled { self.plan = plan }
        }
    }

    func checkFileVault() {
        Task {
            fileVaultOn = await Task.detached { () -> Bool? in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/fdesetup")
                process.arguments = ["isactive"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return nil }
                process.waitUntilExit()
                // isactive exits with 0 when FileVault is on and 1 when it's off.
                switch process.terminationStatus {
                case 0: return true
                case 1: return false
                default: return nil
                }
            }.value
        }
    }

    func shred() {
        guard canShred, let plan else { return }
        let items = plan.accepted
        let total = plan.totalBytes
        let shredder = self.shredder
        confirmation = ""
        phase = .shredding(done: 0, total: total)
        Task {
            do {
                let result = try await Task.detached {
                    try shredder.shred(items) { done in
                        Task { @MainActor in
                            if case .shredding = self.phase { self.phase = .shredding(done: done, total: total) }
                        }
                    }
                }.value
                phase = .done(result)
            } catch {
                errorMessage = error.localizedDescription
                phase = .choosing
            }
        }
    }

    func finish() {
        chosen = []
        plan = nil
        confirmation = ""
        phase = .choosing
    }
}
