import Combine
import Foundation
import TidyCore

@MainActor
final class CloudModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case large = "Large Cloud Files"
        case copies = "Local Copies"

        var id: Self { self }
    }

    enum Phase {
        case idle
        case scanning(path: String?)
        case results
        case cleaning
        case done(CleanResult)
    }

    @Published var mode: Mode = .large {
        didSet { if mode != oldValue { reset() } }
    }
    @Published private(set) var folders: [CloudFolder] = CloudStorage.folders()
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var largeFiles: [CloudFile] = []
    @Published private(set) var copies: [LocalCopyOfCloudFile] = []
    @Published private(set) var selected: Set<UUID> = []
    @Published private(set) var notice: String?
    @Published var errorMessage: String?

    let store: QuarantineStore
    /// Where local copies of cloud files usually pile up.
    let localRoots: [URL] = ["Documents", "Desktop", "Downloads"].map {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0)
    }
    private var task: Task<Void, Never>?

    init(store: QuarantineStore = QuarantineStore(root: QuarantineStore.defaultRoot)) {
        self.store = store
    }

    var selectedItems: [ScanItem] {
        copies.flatMap(\.localCopies).filter { selected.contains($0.id) }.map { item in
            var item = item
            item.isSelected = true
            return item
        }
    }

    func scan() {
        task?.cancel()
        folders = CloudStorage.folders()
        largeFiles = []
        copies = []
        selected = []
        notice = nil
        phase = .scanning(path: nil)
        let folders = self.folders
        let localRoots = self.localRoots
        let mode = self.mode
        task = Task {
            let progress: @Sendable (ScanProgress) -> Void = { update in
                Task { @MainActor in
                    if case .scanning = self.phase {
                        self.phase = .scanning(path: update.currentPath)
                    }
                }
            }
            do {
                switch mode {
                case .large:
                    largeFiles = try await CloudStorage.largeFiles(in: folders, progress: progress)
                case .copies:
                    copies = try await CloudCopyFinder(localRoots: localRoots, cloudFolders: folders).find(progress: progress)
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

    func removeDownload(_ file: CloudFile) {
        do {
            try CloudStorage.removeDownload(file.url)
            notice = "Removed the download of \(file.url.lastPathComponent). It's still in \(file.provider)."
            if let index = largeFiles.firstIndex(of: file) {
                largeFiles[index] = CloudFile(url: file.url, provider: file.provider, size: file.size, localSize: 0)
            }
        } catch {
            errorMessage = "Couldn't remove the download of \(file.url.lastPathComponent). In Finder, right-click it and choose Remove Download. (\(error.localizedDescription))"
        }
    }

    func toggle(_ item: ScanItem) {
        if selected.contains(item.id) {
            selected.remove(item.id)
        } else {
            selected.insert(item.id)
        }
    }

    func selectAllLocalCopies() {
        selected = Set(copies.flatMap(\.localCopies).map(\.id))
    }

    func clean() {
        let items = selectedItems
        let safePaths = CloudCopyFinder(localRoots: localRoots, cloudFolders: folders).safePaths
        phase = .cleaning
        task = Task {
            do {
                let result = try await QuarantineCleaner(store: store, safePaths: safePaths).clean(items, dryRun: false)
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
        largeFiles = []
        copies = []
        selected = []
        notice = nil
        phase = .idle
    }
}
