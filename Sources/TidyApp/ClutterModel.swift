import AppKit
import Combine
import TidyCore

@MainActor
final class ClutterModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case duplicates = "Duplicates"
        case similar = "Similar Photos"
        case large = "Large & Old Files"

        var id: Self { self }
    }

    enum Phase {
        case idle
        case scanning(count: Int, path: String?)
        case results
        case cleaning
        case done(CleanResult)
    }

    @Published var mode: Mode = .duplicates {
        didSet { if mode != oldValue { reset() } }
    }
    @Published private(set) var roots = [FileManager.default.homeDirectoryForCurrentUser]
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var duplicateGroups: [DuplicateGroup] = []
    @Published private(set) var similarGroups: [SimilarPhotoGroup] = []
    @Published private(set) var largeItems: [ScanItem] = []
    @Published private(set) var selected: Set<UUID> = []
    @Published var errorMessage: String?

    let store: QuarantineStore
    private var task: Task<Void, Never>?

    init(store: QuarantineStore = QuarantineStore(root: QuarantineStore.defaultRoot)) {
        self.store = store
    }

    var rootsDescription: String {
        roots.map { DisplayPath.string($0) }.joined(separator: ", ")
    }

    private var allItems: [ScanItem] {
        switch mode {
        case .duplicates: return duplicateGroups.flatMap(\.files)
        case .similar: return similarGroups.flatMap { $0.photos.map(\.item) }
        case .large: return largeItems
        }
    }

    /// Items with their selection applied, ready for review and cleaning.
    var selectedItems: [ScanItem] {
        allItems.filter { selected.contains($0.id) }.map { item in
            var item = item
            item.isSelected = true
            return item
        }
    }

    var largeGroups: [CategorySummary] {
        largeItems.map { item in
            var item = item
            item.isSelected = selected.contains(item.id)
            return item
        }
        .groupedByCategory()
    }

    /// Duplicate groups where every copy is selected; cleaning is blocked while there are any.
    var groupsLosingEveryCopy: [DuplicateGroup] {
        DuplicateFinder.groupsLosingEveryCopy(duplicateGroups, selected: selected)
    }

    /// Similar-photo groups where every photo is selected; cleaning is blocked while there are any.
    var similarGroupsLosingEveryPhoto: [SimilarPhotoGroup] {
        SimilarPhotoFinder.groupsLosingEveryPhoto(similarGroups, selected: selected)
    }

    /// Whether the selection keeps at least one file of every group.
    var keepsOneOfEach: Bool { groupsLosingEveryCopy.isEmpty && similarGroupsLosingEveryPhoto.isEmpty }

    var wastedBytes: Int64 { duplicateGroups.reduce(0) { $0 + $1.wastedBytes } }

    var reclaimablePhotoBytes: Int64 { similarGroups.reduce(0) { $0 + $1.reclaimableBytes } }

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
        duplicateGroups = []
        similarGroups = []
        largeItems = []
        selected = []
        phase = .scanning(count: 0, path: nil)
        let roots = self.roots
        let mode = self.mode
        task = Task {
            let progress: @Sendable (ScanProgress) -> Void = { update in
                Task { @MainActor in
                    if case .scanning = self.phase {
                        self.phase = .scanning(count: update.completed, path: update.currentPath)
                    }
                }
            }
            do {
                switch mode {
                case .duplicates:
                    duplicateGroups = try await DuplicateFinder(roots: roots).find(progress: progress)
                case .similar:
                    similarGroups = try await SimilarPhotoFinder(roots: roots).find(progress: progress)
                case .large:
                    largeItems = try await LargeFileFinder(roots: roots).scan(progress: progress)
                }
                phase = .results
            } catch is CancellationError {
                phase = .idle
            } catch {
                errorMessage = error.localizedDescription
                phase = .idle
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func toggle(_ item: ScanItem) {
        if selected.contains(item.id) {
            selected.remove(item.id)
        } else {
            selected.insert(item.id)
        }
    }

    func setCategory(_ category: String, selected isSelected: Bool) {
        for item in largeItems where item.category == category {
            if isSelected {
                selected.insert(item.id)
            } else {
                selected.remove(item.id)
            }
        }
    }

    func selectAllButOldest() {
        selected = DuplicateFinder.selectAllButOldest(duplicateGroups)
    }

    func selectAllButBest() {
        selected = SimilarPhotoFinder.selectAllButBest(similarGroups)
    }

    func clearSelection() {
        selected = []
    }

    func clean() {
        guard keepsOneOfEach else { return }
        let chosen = selectedItems
        let safePaths = SafePaths(allowedRoots: roots)
        phase = .cleaning
        task = Task {
            do {
                let result = try await QuarantineCleaner(store: store, safePaths: safePaths).clean(chosen, dryRun: false)
                phase = .done(result)
            } catch {
                errorMessage = error.localizedDescription
                phase = .results
            }
        }
    }

    func undo(_ batch: QuarantineBatch) {
        do {
            _ = try store.restore(batchID: batch.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        reset()
    }

    func reset() {
        task?.cancel()
        duplicateGroups = []
        similarGroups = []
        largeItems = []
        selected = []
        phase = .idle
    }
}
