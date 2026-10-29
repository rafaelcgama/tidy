import AppKit
import Combine
import TidyCore

/// Scan → review → move to quarantine → undo, for any scanner whose items are listed by category.
@MainActor
final class ScanCleanModel: ObservableObject {
    typealias MakeScanner = () -> (scanner: any TidyCore.Scanner, safePaths: SafePaths)

    enum Phase {
        case idle
        case scanning(path: String?)
        case results
        case cleaning
        case done(CleanResult)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var items: [ScanItem] = []
    @Published var errorMessage: String?
    @Published private(set) var notice: String?

    let store: QuarantineStore
    private let makeScanner: MakeScanner
    private let preflight: (([ScanItem]) -> String?)?
    private var safePaths = SafePaths(allowedRoots: [])
    private var task: Task<Void, Never>?
    private var appChanges: AnyCancellable?

    /// `preflight` says why the selection can't be cleaned yet (say, an app that must be quit first).
    init(store: QuarantineStore = QuarantineStore(root: QuarantineStore.defaultRoot),
         preflight: (([ScanItem]) -> String?)? = nil,
         makeScanner: @escaping MakeScanner) {
        self.store = store
        self.preflight = preflight
        self.makeScanner = makeScanner
        if preflight != nil {
            // Apps quitting or launching can change the answer, so the screen re-checks.
            let center = NSWorkspace.shared.notificationCenter
            appChanges = center.publisher(for: NSWorkspace.didTerminateApplicationNotification)
                .merge(with: center.publisher(for: NSWorkspace.didLaunchApplicationNotification))
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }

    var groups: [CategorySummary] { items.groupedByCategory() }
    var selectedItems: [ScanItem] { items.filter(\.isSelected) }
    var selectedSize: Int64 { items.selectedSize }
    var blocker: String? { preflight?(selectedItems) }

    func scan() {
        task?.cancel()
        items = []
        notice = nil
        phase = .scanning(path: nil)
        let made = makeScanner()
        safePaths = made.safePaths
        let scanner = made.scanner
        task = Task {
            do {
                let found = try await scanner.scan { progress in
                    Task { @MainActor in
                        if case .scanning = self.phase {
                            self.phase = .scanning(path: progress.currentPath)
                        }
                    }
                }
                items = found
                phase = .results
            } catch is CancellationError {
                phase = .idle
            } catch {
                errorMessage = error.localizedDescription
                phase = .idle
            }
        }
    }

    func cancelScan() {
        task?.cancel()
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

    func clean() {
        guard blocker == nil else { return }
        let chosen = selectedItems
        let safePaths = self.safePaths
        phase = .cleaning
        task = Task {
            do {
                let cleaner = AdminAwareCleaner.forApp(store: store, safePaths: safePaths)
                let result = try await cleaner.clean(chosen, dryRun: false)
                phase = .done(result)
            } catch {
                errorMessage = error.localizedDescription
                phase = .results
            }
        }
    }

    func undo(_ batch: QuarantineBatch) {
        let cleaner = AdminAwareCleaner.forApp(store: store, safePaths: safePaths)
        task = Task {
            do {
                let result = try await cleaner.undo(batchID: batch.id)
                notice = "Restored \(result.restored.count) items."
                    + (result.skipped.isEmpty ? "" : " \(result.skipped.count) could not be put back.")
            } catch {
                errorMessage = error.localizedDescription
            }
            items = []
            phase = .idle
        }
    }

    func reset() {
        task?.cancel()
        items = []
        notice = nil
        phase = .idle
    }
}
