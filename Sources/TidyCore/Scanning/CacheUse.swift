import Foundation

/// A cache an app is using keeps it fast, and removing it only means the app rebuilds it. So a cache
/// starts selected only when nothing in it has changed for a while.
public enum CacheUse {
    public static let days = 30

    /// Whether a cache last written at `lastModified` still counts as in use at `now`.
    public static func isInUse(lastModified: Date?, now: Date) -> Bool {
        guard let lastModified else { return false }
        return now.timeIntervalSince(lastModified) < TimeInterval(days) * 86_400
    }
}
