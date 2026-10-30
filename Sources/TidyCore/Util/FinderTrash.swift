import Foundation

/// Finder's Trash, as the Dock opens it: what you deleted on this Mac, in iCloud Drive and on other disks.
/// Opening the ~/.Trash folder shows only this Mac's part, so Tidy asks Finder instead, which macOS lets
/// it do once you allow Tidy to control Finder (Privacy & Security › Automation).
public struct FinderTrash: Sendable {
    let osascript: URL

    public init(osascript: URL = URL(fileURLWithPath: "/usr/bin/osascript")) {
        self.osascript = osascript
    }

    static let arguments = ["-e", "tell application \"Finder\"", "-e", "open trash", "-e", "activate", "-e", "end tell"]

    /// Whether Finder opened it. The first time, macOS asks whether Tidy may control Finder and this waits
    /// for the answer, so call it off the main thread.
    public func open() -> Bool {
        (try? Subprocess.run(osascript, Self.arguments))?.status == 0
    }
}
