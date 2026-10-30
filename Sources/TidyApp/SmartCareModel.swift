import Combine
import Foundation
import TidyCore

@MainActor
final class SmartCareModel: ObservableObject {
    enum Phase {
        case idle
        case running(step: String)
        case report(SmartCareReport)
        case cleaning
        case done(CleanResult)
    }

    /// The Junk Mail card: whether Mail is marking the junk, and what came of it.
    enum MailJunkStatus: Equatable {
        case ready
        case marking
        case finished(MailJunk.Outcome)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var mailJunk: MailJunkStatus = .ready
    @Published var errorMessage: String?

    let store: QuarantineStore
    private var task: Task<Void, Never>?

    init(store: QuarantineStore = QuarantineStore(root: QuarantineStore.defaultRoot)) {
        self.store = store
    }

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

    func clean(_ report: SmartCareReport) {
        let items = report.selectedCleanup
        phase = .cleaning
        task = Task {
            do {
                let result = try await AdminAwareCleaner.forApp(store: store, safePaths: report.safePaths).clean(items, dryRun: false)
                phase = .done(result)
            } catch {
                errorMessage = error.localizedDescription
                phase = .report(report)
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
            phase = .idle
        }
    }

    func reset() {
        phase = .idle
    }

    /// Asks Mail to mark the unread junk in every account as read.
    func markMailJunkRead() {
        mailJunk = .marking
        Task {
            mailJunk = .finished(await Task.detached { MailJunk().markRead() }.value)
        }
    }
}
