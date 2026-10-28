import AppKit
import Combine
import TidyCore

/// Launch jobs (login items, agents, daemons) and the threat heuristics that run over them.
@MainActor
final class ProtectionModel: ObservableObject {
    @Published private(set) var items: [LaunchItem] = []
    @Published private(set) var findings: [Finding] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var notice: String?
    @Published var errorMessage: String?

    let store: QuarantineStore
    private let userAgents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    private let systemFolders = [URL(fileURLWithPath: "/Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchDaemons")]
    private var lastBatch: QuarantineBatch?

    init(store: QuarantineStore = QuarantineStore(root: QuarantineStore.defaultRoot)) {
        self.store = store
    }

    var dangerCount: Int { findings.filter { $0.severity == .danger }.count }

    func refresh() {
        isLoading = true
        Task {
            let (items, findings) = await Task.detached { () -> ([LaunchItem], [Finding]) in
                let items = LaunchItemReader.items(in: LaunchItemReader.defaultFolders())
                return (items, PersistenceAuditor().audit(items) + BrowserPolicyAuditor().audit())
            }.value
            self.items = items
            self.findings = findings
            isLoading = false
            hasLoaded = true
        }
    }

    /// Jobs in your own LaunchAgents folder can always be removed. The ones in /Library need
    /// administrator rights (the admin helper, or macOS asks for a password), and macOS's own stay.
    func canRemove(_ url: URL) -> Bool {
        let folder = url.deletingLastPathComponent().standardizedFileURL.path
        if folder == userAgents.standardizedFileURL.path { return true }
        return systemFolders.contains { $0.path == folder } && HelperPolicy.standard.accepts(url)
    }

    /// Moves a job's plist to quarantine, so it no longer starts at login. Undo puts it back.
    func remove(_ url: URL, name: String) {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let isDaemon = url.deletingLastPathComponent().path == "/Library/LaunchDaemons"
        let item = ScanItem(url: url, size: size, category: isDaemon ? "Launch daemon" : "Launch agent", isSelected: true)
        let cleaner = AdminAwareCleaner.forApp(store: store, safePaths: SafePaths(allowedRoots: [userAgents] + systemFolders))
        Task {
            do {
                let result = try await cleaner.clean([item], dryRun: false)
                if let batch = result.batch {
                    lastBatch = batch
                    notice = "\(name) won't start the next time you log in or restart. It's in quarantine for \(store.retentionDays) days."
                } else {
                    errorMessage = "Couldn't move \(name): \(result.skipped.first?.reason ?? "unknown reason")."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            refresh()
        }
    }

    func undoLast() {
        guard let batch = lastBatch else { return }
        let cleaner = AdminAwareCleaner.forApp(store: store, safePaths: SafePaths(allowedRoots: []))
        Task {
            do {
                _ = try await cleaner.undo(batchID: batch.id)
                notice = nil
                lastBatch = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            refresh()
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
