import AppKit
import TidyCore

enum BrowserCheck {
    /// Browsers must be quit before their data is moved, or they write it straight back.
    static func browsersToQuit(_ items: [ScanItem]) -> String? {
        let running = PrivacyScanner().browsers(owning: items)
            .filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty }
            .map(\.name)
        guard !running.isEmpty else { return nil }
        return "Quit \(ListFormatter.localizedString(byJoining: running)) first, so the data isn't written back"
    }
}
