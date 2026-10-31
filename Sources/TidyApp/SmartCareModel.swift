import Combine
import Foundation
import TidyCore

@MainActor
final class SmartCareModel: ObservableObject {
    enum Phase {
        case idle
        case running(step: String)
        case report(SmartCareReport)
        /// The report's junk, listed by kind to tick item by item.
        case choosing(SmartCareReport)
        case cleaning
        case done(CleanResult)
    }

    /// The Junk and Trash Mail card: whether Mail is marking the messages, and what came of it.
    enum MailJunkStatus: Equatable {
        case ready
        case marking
        case finished(MailJunk.Outcome)
    }

    @Published private(set) var phase: Phase = .idle
    /// The junk the last scan found, with your ticks. What's safe to remove starts ticked.
    @Published private(set) var cleanup: [ScanItem] = []
    @Published private(set) var mailJunk: MailJunkStatus = .ready
    @Published var errorMessage: String?

    let store: QuarantineStore
    private var task: Task<Void, Never>?

    init(store: QuarantineStore = QuarantineStore(root: QuarantineStore.defaultRoot)) {
        self.store = store
    }

    var cleanupGroups: [CategorySummary] { cleanup.groupedByCategory() }
    var selectedCleanup: [ScanItem] { cleanup.filter(\.isSelected) }
    var allCleanupSelected: Bool { !cleanup.isEmpty && cleanup.allSatisfy(\.isSelected) }

    func run() {
        task?.cancel()
        phase = .running(step: "Starting…")
        if case .finished = mailJunk { mailJunk = .ready }
        task = Task {
            do {
                let report = try await SmartCare.standard().run { step in
                    Task { @MainActor in
                        if case .running = self.phase {
                            self.phase = .running(step: step)
                        }
                    }
                }
                cleanup = report.cleanup
                phase = .report(report)
                ReminderModel.shared.recordScan(.smartCare)
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

    /// Lists the junk by kind, to tick item by item.
    func choose(_ report: SmartCareReport) {
        phase = .choosing(report)
    }

    /// Back to the report, keeping the ticks.
    func closeList(_ report: SmartCareReport) {
        phase = .report(report)
    }

    func toggle(_ item: ScanItem) {
        guard let index = cleanup.firstIndex(where: { $0.id == item.id }) else { return }
        cleanup[index].isSelected.toggle()
    }

    func setCategory(_ category: String, selected: Bool) {
        for index in cleanup.indices where cleanup[index].category == category {
            cleanup[index].isSelected = selected
        }
    }

    func selectAll(_ selected: Bool) {
        for index in cleanup.indices {
            cleanup[index].isSelected = selected
        }
    }

    /// Moves the items to quarantine. They come from the report's list, which is shown again if it fails.
    func clean(_ items: [ScanItem], from report: SmartCareReport) {
        phase = .cleaning
        task = Task {
            do {
                let result = try await AdminAwareCleaner.forApp(store: store, safePaths: report.safePaths).clean(items, dryRun: false)
                phase = .done(result)
            } catch {
                errorMessage = error.localizedDescription
                phase = .choosing(report)
            }
        }
    }

    func undo(_ batch: QuarantineBatch) {
        let cleaner = AdminAwareCleaner.forApp(store: store, safePaths: SafePaths(allowedRoots: []))
        task = Task {
            do {
                _ = try await cleaner.undo(batchID: batch.id)
            } catch {
                errorMessage = error.localizedDescription
            }
            reset()
        }
    }

    func reset() {
        cleanup = []
        phase = .idle
    }

    /// Asks Mail to mark the unread messages in Junk and Trash, in every account, as read.
    func markMailJunkRead() {
        mailJunk = .marking
        Task {
            mailJunk = .finished(await Task.detached { MailJunk().markRead() }.value)
        }
    }
}
