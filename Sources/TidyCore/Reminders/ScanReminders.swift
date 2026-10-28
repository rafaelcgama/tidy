import Foundation

/// Reminders to run a scan. Tidy never scans on its own and never sends notifications: a due reminder
/// only shows inside Tidy, saying how long it has been since your last scan.
public struct ScanReminders: Codable, Equatable, Sendable {
    public enum Scan: String, Codable, CaseIterable, Sendable {
        case smartCare, malware
    }

    public struct Reminder: Codable, Equatable, Sendable {
        public var isEnabled = false
        /// Remind once the last scan is this many days old.
        public var days: Int
        /// When you last finished this scan.
        public var lastScan: Date?
        /// When you turned the reminder on. Without a last scan, the days count from here.
        public var enabledAt: Date?

        public init(days: Int) {
            self.days = days
        }

        /// When the reminder comes due, or nil while it's off.
        public func dueDate(calendar: Calendar = .current) -> Date? {
            guard isEnabled, let start = lastScan ?? enabledAt else { return nil }
            return calendar.date(byAdding: .day, value: max(days, 1), to: start)
        }

        public func isDue(now: Date, calendar: Calendar = .current) -> Bool {
            guard let due = dueDate(calendar: calendar) else { return false }
            return due <= now
        }

        /// Calendar days since the last scan, or nil when there was none.
        public func daysSinceLastScan(now: Date, calendar: Calendar = .current) -> Int? {
            guard let lastScan else { return nil }
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: lastScan),
                                               to: calendar.startOfDay(for: now)).day ?? 0
            return max(days, 0)
        }

        /// "Today", "Yesterday", "3 days ago" or "Never".
        public func lastScanText(now: Date, calendar: Calendar = .current) -> String {
            guard let days = daysSinceLastScan(now: now, calendar: calendar) else { return "Never" }
            switch days {
            case 0: return "Today"
            case 1: return "Yesterday"
            default: return "\(days) days ago"
            }
        }
    }

    /// A reminder that is due, with the line to show for it.
    public struct Due: Identifiable, Equatable, Sendable {
        public let scan: Scan
        public let text: String

        public var id: Scan { scan }
    }

    public var smartCare = Reminder(days: 14)
    public var malware = Reminder(days: 30)

    public init() {}

    public subscript(scan: Scan) -> Reminder {
        get {
            switch scan {
            case .smartCare: return smartCare
            case .malware: return malware
            }
        }
        set {
            switch scan {
            case .smartCare: smartCare = newValue
            case .malware: malware = newValue
            }
        }
    }

    /// The reminders that are due, Smart Care first.
    public func due(now: Date, calendar: Calendar = .current) -> [Due] {
        Scan.allCases.compactMap { scan in
            let reminder = self[scan]
            guard reminder.isDue(now: now, calendar: calendar) else { return nil }
            return Due(scan: scan, text: Self.text(for: scan, daysSinceLastScan: reminder.daysSinceLastScan(now: now, calendar: calendar)))
        }
    }

    static func text(for scan: Scan, daysSinceLastScan days: Int?) -> String {
        let name = scan == .smartCare ? "Smart Care scan" : "malware Quick Scan"
        guard let days else { return "You haven't run a \(name) yet." }
        return "It's been \(days == 1 ? "1 day" : "\(days) days") since your last \(name)."
    }
}

/// Keeps the reminders as JSON in Tidy's Application Support folder.
public struct ScanReminderStore: Sendable {
    public let url: URL

    public init(url: URL = ScanReminderStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tidy/reminders.json")
    }

    /// The saved reminders, or new ones (all off) when there are none or they can't be read.
    public func load() -> ScanReminders {
        guard let data = try? Data(contentsOf: url),
              let reminders = try? Self.decoder.decode(ScanReminders.self, from: data)
        else { return ScanReminders() }
        return reminders
    }

    public func save(_ reminders: ScanReminders) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(reminders).write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
