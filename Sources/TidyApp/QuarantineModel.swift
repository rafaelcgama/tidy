import AppKit
import Combine
import TidyCore

/// Everything Tidy moved to quarantine within the retention period, putting any of it back, and
/// deleting it for good sooner when you ask.
@MainActor
final class QuarantineModel: ObservableObject {
    @Published private(set) var batches: [QuarantineBatch] = []
    @Published private(set) var restoring: String?
    @Published private(set) var deleting = false
    @Published private(set) var notice: String?
    @Published var errorMessage: String?
    /// What the confirmation shows before anything is deleted for good.
    @Published var pendingDeletion: [QuarantineBatch]?

    let store: QuarantineStore

    init(store: QuarantineStore = QuarantineStore(root: QuarantineStore.defaultRoot)) {
        self.store = store
    }

    private var cleaner: AdminAwareCleaner {
        AdminAwareCleaner.forApp(store: store, safePaths: SafePaths(allowedRoots: []))
    }

    func refresh() {
        batches = cleaner.batches()
    }

    func restore(_ batch: QuarantineBatch) {
        let cleaner = self.cleaner
        restoring = batch.id
        notice = nil
        Task {
            do {
                let result = try await cleaner.undo(batchID: batch.id)
                var text = "Put back \(result.restored.count) of \(batch.entries.count) items."
                if !result.skipped.isEmpty {
                    let reasons = result.skipped.prefix(3).map {
                        "\(URL(fileURLWithPath: $0.entry.originalPath).lastPathComponent) (\($0.reason))"
                    }
                    text += " Not put back: " + reasons.joined(separator: ", ") + (result.skipped.count > 3 ? "…" : ".")
                }
                notice = text
            } catch {
                errorMessage = error.localizedDescription
            }
            restoring = nil
            refresh()
        }
    }

    var totalSize: Int64 { batches.reduce(0) { $0 + $1.totalSize } }

    /// Whether macOS will ask for an administrator's password to delete these: part of them belongs
    /// to the system, and the admin helper isn't installed.
    func needsPassword(_ batches: [QuarantineBatch]) -> Bool {
        let system = QuarantineStore(root: QuarantineStore.systemRoot)
        return !AdminHelper.shared.isEnabled && batches.contains { system.hasBatch($0.id) }
    }

    /// Deletes batches for good, after the confirmation. None of it can be put back after.
    func deleteForGood(_ chosen: [QuarantineBatch]) {
        let cleaner = self.cleaner
        pendingDeletion = nil
        deleting = true
        notice = nil
        Task {
            do {
                let deleted = try await cleaner.delete(batchIDs: chosen.map(\.id))
                let count = deleted.reduce(0) { $0 + $1.entries.count }
                let size = deleted.reduce(0) { $0 + $1.totalSize }
                notice = "Deleted \(count) items (\(ByteFormat.string(size))) for good."
            } catch AdminPrompt.Failure.cancelled {
                notice = "Nothing was deleted: no password was entered."
            } catch {
                errorMessage = error.localizedDescription
            }
            deleting = false
            refresh()
        }
    }

    func reveal(_ batch: QuarantineBatch) {
        let own = store.root.appendingPathComponent(batch.id)
        let folder = FileManager.default.fileExists(atPath: own.path) ? own : QuarantineStore.systemRoot.appendingPathComponent(batch.id)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// Days until the batch is deleted for good.
    func daysLeft(_ batch: QuarantineBatch) -> Int {
        let expiry = batch.date.addingTimeInterval(Double(store.retentionDays) * 86_400)
        return max(0, Int((expiry.timeIntervalSinceNow / 86_400).rounded(.up)))
    }
}
