import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Stops a launch agent before Tidy moves its plist to quarantine, and starts it again when it's put back.
public enum LaunchJobControl {
    static let launchctl = "/bin/launchctl"

    /// A plist in your own LaunchAgents folder or in the one for every user: its job runs in your
    /// login session, so you can stop and start it without administrator rights.
    public static func isAgent(_ plist: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let folder = plist.deletingLastPathComponent().path
        return plist.pathExtension == "plist"
            && (folder == home.appendingPathComponent("Library/LaunchAgents").path || folder == "/Library/LaunchAgents")
    }

    /// Stops an agent before its plist is removed, or starts it again once the plist is back, so
    /// neither has to wait for the next login. Best effort: launchctl may not know the job.
    @Sendable public static func changeAgent(_ plist: URL, start: Bool) {
        guard isAgent(plist) else { return }
        let domain = "gui/\(getuid())"
        _ = try? Subprocess.run(URL(fileURLWithPath: launchctl), [start ? "bootstrap" : "bootout", domain, plist.path])
    }
}
