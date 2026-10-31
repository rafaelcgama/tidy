import AppKit
import Combine
import TidyCore

@MainActor
final class UninstallerModel: ObservableObject {
    enum Sort: String, CaseIterable, Identifiable {
        case name = "Name"
        case lastOpened = "Last Opened"

        var id: Self { self }
    }

    enum Phase {
        case empty
        case scanning
        case results
        case removing
        case done(CleanResult)
    }

    @Published private(set) var apps: [InstalledApp] = []
    @Published var search = ""
    @Published var sort: Sort = .name
    /// When each app was last opened, by app id; missing when there's no record.
    @Published private(set) var lastOpened: [String: Date] = [:]
    @Published var selection: InstalledApp? {
        didSet { if selection != oldValue { scanSelection() } }
    }
    @Published private(set) var phase: Phase = .empty
    @Published private(set) var items: [ScanItem] = []
    @Published private(set) var isRunning = false
    @Published var errorMessage: String?

    let store: QuarantineStore
    let finder: LeftoverFinder
    private var installedBundleIDs: Set<String> = []
    private var loadTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private let watcher = FolderWatcher()

    init(store: QuarantineStore = QuarantineStore(root: QuarantineStore.defaultRoot), finder: LeftoverFinder = LeftoverFinder()) {
        self.store = store
        self.finder = finder
        // Whenever an app is added to or removed from Applications, the list follows.
        watcher.onChange = { [weak self] in self?.loadApps() }
    }

    var filteredApps: [InstalledApp] {
        let shown = search.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
        guard sort == .lastOpened else { return shown }
        // Longest unused first, and apps never opened before all of them.
        return shown.sorted { a, b in
            let first = lastOpened[a.id] ?? .distantPast, second = lastOpened[b.id] ?? .distantPast
            return first != second ? first < second : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    func usageText(_ app: InstalledApp) -> String {
        AppUsage.text(lastOpened: lastOpened[app.id], now: Date())
    }

    func isUnused(_ app: InstalledApp) -> Bool {
        AppUsage.isUnused(lastOpened: lastOpened[app.id], now: Date())
    }

    var groups: [CategorySummary] { items.groupedByCategory() }
    var selectedItems: [ScanItem] { items.filter(\.isSelected) }
    var allSelected: Bool { !items.isEmpty && items.allSatisfy(\.isSelected) }

    func loadApps() {
        loadTask?.cancel()
        loadTask = Task {
            let (apps, ids, usage) = await Task.detached { () -> ([InstalledApp], Set<String>, [String: Date]) in
                let apps = AppInventory.apps(in: AppInventory.defaultFolders())
                let system = AppInventory.apps(in: AppInventory.systemFolders)
                var usage: [String: Date] = [:]
                for app in apps {
                    usage[app.id] = AppUsage.lastOpened(app.url)
                }
                return (apps, Set((apps + system).map(\.bundleID)), usage)
            }.value
            self.apps = apps
            self.installedBundleIDs = ids
            self.lastOpened = usage
            watcher.watch(AppInventory.foldersHoldingApps(AppInventory.defaultFolders()))
        }
    }

    private func makeScanner(for app: InstalledApp) -> UninstallScanner {
        UninstallScanner(app: app, finder: finder, systemFinder: .system, packages: .system, installedBundleIDs: installedBundleIDs)
    }

    func scanSelection() {
        scanTask?.cancel()
        items = []
        guard let selection else {
            phase = .empty
            return
        }
        phase = .scanning
        refreshRunning()
        let scanner = makeScanner(for: selection)
        scanTask = Task {
            do {
                let found = try await scanner.scan { _ in }
                items = found
                phase = .results
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                phase = .empty
            }
        }
    }

    func toggle(_ item: ScanItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isSelected.toggle()
    }

    func setCategory(_ category: String, selected: Bool) {
        for index in items.indices where items[index].category == category {
            items[index].isSelected = selected
        }
    }

    func selectAll(_ selected: Bool) {
        for index in items.indices {
            items[index].isSelected = selected
        }
    }

    func refreshRunning() {
        guard let app = selection else {
            isRunning = false
            return
        }
        isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
    }

    func quitSelectedApp() {
        guard let app = selection else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).forEach { $0.terminate() }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            refreshRunning()
        }
    }

    func remove(_ chosen: [ScanItem]) {
        guard let selection else { return }
        let safePaths = makeScanner(for: selection).safePaths
        phase = .removing
        scanTask = Task {
            do {
                let result = try await AdminAwareCleaner.forApp(store: store, safePaths: safePaths).clean(chosen, dryRun: false)
                apps.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
                phase = .done(result)
            } catch {
                errorMessage = error.localizedDescription
                phase = .results
            }
        }
    }

    func undo(_ batch: QuarantineBatch) {
        let cleaner = AdminAwareCleaner.forApp(store: store, safePaths: SafePaths(allowedRoots: []))
        Task {
            do {
                _ = try await cleaner.undo(batchID: batch.id)
            } catch {
                errorMessage = error.localizedDescription
            }
            loadApps()
            scanSelection()
        }
    }

    func finish() {
        selection = nil
    }
}

/// Calls `onChange` shortly after anything is added to, removed from or renamed in the folders it watches.
@MainActor
final class FolderWatcher {
    var onChange: (() -> Void)?
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pending: DispatchWorkItem?

    /// Watches exactly these folders from now on.
    func watch(_ folders: [URL]) {
        let paths = Set(folders.map(\.path))
        for (path, source) in sources where !paths.contains(path) {
            source.cancel()
            sources[path] = nil
        }
        for path in paths where sources[path] == nil {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in self?.changed() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources[path] = source
        }
    }

    /// Installers copy an app in many steps; wait until they've settled before reading the folder again.
    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange?() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    deinit {
        sources.values.forEach { $0.cancel() }
    }
}
