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
    /// When the last check finished, so Scan Again visibly does something.
    @Published private(set) var lastChecked: Date?
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
            lastChecked = Date()
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

    /// A System Settings page, such as the one listing the apps that may use the camera.
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Opens a browser, on its page of site permissions when it has one that can be opened from outside.
    func open(_ browser: Browser) {
        var arguments = ["-a", browser.app.path]
        if let page = browser.page { arguments.append(page) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            errorMessage = "Couldn't open \(browser.name): \(error.localizedDescription)"
        }
    }
}

/// A browser installed on this Mac, and the page in it that lists what each website may use.
struct Browser: Identifiable {
    let name: String
    let app: URL
    /// Nil when the browser has no page another app can open, like Safari.
    let page: String?
    let hint: String
    var id: String { name }

    private static let known: [(name: String, bundleID: String, page: String?)] = [
        ("Chrome", "com.google.Chrome", "chrome://settings/content"),
        ("Firefox", "org.mozilla.firefox", "about:preferences#privacy"),
        ("Edge", "com.microsoft.edgemac", "edge://settings/content"),
        ("Brave", "com.brave.Browser", "brave://settings/content"),
        ("Safari", "com.apple.Safari", nil),
    ]

    /// The browsers macOS knows are installed, in a fixed order.
    static func installed() -> [Browser] {
        known.compactMap { entry in
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID) else { return nil }
            let hint = entry.page == nil
                ? "\(entry.name) doesn't let apps open this page: in \(entry.name), choose Settings › Websites"
                : "Websites allowed to use your camera, microphone, location, notifications and more"
            return Browser(name: entry.name, app: app, page: entry.page, hint: hint)
        }
    }
}
