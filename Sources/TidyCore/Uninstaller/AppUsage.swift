import Foundation
#if canImport(CoreServices)
import CoreServices
#endif

/// When you last opened an app, as Spotlight records it: Finder's "Last opened".
public enum AppUsage {
    /// Apps not opened for this many days count as unused.
    public static let unusedAfterDays = 180

    /// Nil when there's no record of the app being opened.
    public static func lastOpened(_ appURL: URL) -> Date? {
        #if canImport(CoreServices)
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, appURL as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        #else
        return nil
        #endif
    }

    /// "Opened today", "Opened 3 days ago", "Opened 5 months ago", "Opened 2 years ago" or "Never opened".
    public static func text(lastOpened: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let lastOpened else { return "Never opened" }
        let days = max(calendar.dateComponents([.day], from: calendar.startOfDay(for: lastOpened),
                                               to: calendar.startOfDay(for: now)).day ?? 0, 0)
        switch days {
        case 0: return "Opened today"
        case 1: return "Opened yesterday"
        case ..<30: return "Opened \(days) days ago"
        case ..<365:
            let months = days / 30
            return months == 1 ? "Opened a month ago" : "Opened \(months) months ago"
        default:
            let years = days / 365
            return years == 1 ? "Opened a year ago" : "Opened \(years) years ago"
        }
    }

    /// Never opened, or not for `unusedAfterDays`.
    public static func isUnused(lastOpened: Date?, now: Date) -> Bool {
        guard let lastOpened else { return true }
        return now.timeIntervalSince(lastOpened) >= TimeInterval(unusedAfterDays) * 86_400
    }
}
