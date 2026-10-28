import AppKit
import Combine
import TidyCore

/// The scan reminders, for Smart Care, Malware Scan, Settings and the menu bar panel. It never scans
/// and never sends notifications: a due reminder only shows inside Tidy, and you start the scan yourself.
@MainActor
final class ReminderModel: ObservableObject {
    static let shared = ReminderModel()

    @Published var reminders: ScanReminders {
        didSet {
            guard reminders != oldValue else { return }
            save()
        }
    }
    /// Moves forward every few minutes, so "3 days ago" and due reminders stay current.
    @Published private(set) var now = Date()
    @Published var errorMessage: String?

    private let store: ScanReminderStore
    private var timer: Timer?
    private var wake: AnyCancellable?

    private init(store: ScanReminderStore = ScanReminderStore()) {
        self.store = store
        reminders = store.load()
        let timer = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // After sleep the counts may be days behind.
        wake = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    var due: [ScanReminders.Due] { reminders.due(now: now) }

    func lastScanText(_ scan: ScanReminders.Scan) -> String {
        reminders[scan].lastScanText(now: now)
    }

    /// Turning a reminder on starts its count, for scans you never ran.
    func setEnabled(_ on: Bool, for scan: ScanReminders.Scan) {
        var reminder = reminders[scan]
        guard reminder.isEnabled != on else { return }
        reminder.isEnabled = on
        if on { reminder.enabledAt = Date() }
        reminders[scan] = reminder
        refresh()
    }

    /// Call when you finish a scan; its reminder counts from here.
    func recordScan(_ scan: ScanReminders.Scan) {
        reminders[scan].lastScan = Date()
        refresh()
    }

    func refresh() {
        now = Date()
    }

    private func save() {
        do {
            try store.save(reminders)
        } catch {
            errorMessage = "Couldn't save the reminders: \(error.localizedDescription)"
        }
    }
}
