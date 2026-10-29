import AppKit
import Combine
import TidyCore

/// Scan → review → move to quarantine → undo, for any scanner whose items are listed by category.
@MainActor
final class ScanCleanModel: ObservableObject {
    typealias MakeScanner = ([URL]) -> (scanner: any TidyCore.Scanner, safePaths: SafePaths)

    enum Phase {
        case idle
        case scanning(path: String?)
        case results
        case cleaning
        case done(CleanResult)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var items: [ScanItem] = []
    @Published private(set) var roots: [URL]
    @Published var errorMessage: String?
    @Published private(set) var notice: String?

    let store: QuarantineStore
    private let makeScanner: MakeScanner
    private var safePaths = SafePaths(allowedRoots: [])
    private var task: Task<Void, Never>?

    init(roots: [URL] = [],
         store: QuarantineStore = QuarantineStore(root: QuarantineStore.defaultRoot),
         makeScanner: @escaping MakeScanner) {
        self.roots = roots
        self.store = store
        self.makeScanner = makeScanner
    }

    var groups: [CategorySummary] { items.groupedByCategory() }
    var selectedItems: [ScanItem] { items.filter(\.isSelected) }
    var selectedSize: Int64 { items.selectedSize }

    var rootsDescription: String {
        roots.map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }.joined(separator: ", ")
    }

    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = roots.first
        panel.prompt = "Choose"
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            roots = panel.urls
            reset()
        }
    }

    func scan() {
        task?.cancel()
        items = []
        notice = nil
        phase = .scanning(path: nil)
        let made = makeScanner(roots)
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
