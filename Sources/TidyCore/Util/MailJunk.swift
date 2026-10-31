import Foundation

/// Mail's Junk and Trash, in every account. Tidy asks Mail to mark what's unread there as read, which macOS lets
/// it do once you allow Tidy to control Mail (Privacy & Security › Automation). Mail does the marking and passes
/// it on to each account's server; Tidy never opens Mail's files.
public struct MailJunk: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// How many messages Mail marked as read.
        case marked(Int)
        /// macOS didn't let Tidy control Mail.
        case notAllowed
        /// Mail didn't mark them, with what it said.
        case failed(String)
    }

    let osascript: URL

    public init(osascript: URL = URL(fileURLWithPath: "/usr/bin/osascript")) {
        self.osascript = osascript
    }

    /// Mail's Junk and Trash each hold one mailbox per account. Each is asked in turn, then Junk and Trash
    /// themselves, for what's kept only on this Mac. What one marks, the next finds already read, so nothing is
    /// counted twice.
    static let script = [
        "tell application id \"com.apple.mail\"",
        "  try",
        "    set theBoxes to every mailbox of junk mailbox",
        "  on error errorText number errorNumber",
        "    if errorNumber is -1743 then error errorText number errorNumber",
        "    set theBoxes to {}",
        "  end try",
        "  set end of theBoxes to junk mailbox",
        "  try",
        "    set theBoxes to theBoxes & (every mailbox of trash mailbox)",
        "  on error errorText number errorNumber",
        "    if errorNumber is -1743 then error errorText number errorNumber",
        "  end try",
        "  set end of theBoxes to trash mailbox",
        "  set markedCount to 0",
        "  set missedBoxes to 0",
        "  repeat with i from 1 to count of theBoxes",
        "    set theBox to item i of theBoxes",
        "    try",
        "      with timeout of 600 seconds",
        "        set unreadHere to count (every message of theBox whose read status is false)",
        "        if unreadHere > 0 then set read status of every message of theBox whose read status is false to true",
        "      end timeout",
        "      set markedCount to markedCount + unreadHere",
        "    on error",
        "      set missedBoxes to missedBoxes + 1",
        "    end try",
        "  end repeat",
        "  if missedBoxes = (count of theBoxes) then error \"Mail has no Junk or Trash mailbox it could open.\"",
        "  return markedCount",
        "end tell",
    ]

    static var arguments: [String] { script.flatMap { ["-e", $0] } }

    /// Marks the unread messages in Junk and Trash, in every account, as read. If Mail isn't open, it opens. The
    /// first time, macOS asks whether Tidy may control Mail and this waits for the answer, so call it off the main
    /// thread.
    public func markRead() -> Outcome {
        guard let result = try? Subprocess.run(osascript, Self.arguments) else {
            return .failed("Tidy couldn't ask Mail.")
        }
        guard result.status == 0 else {
            let error = AppleScriptError(result.errors)
            // AppleScript's "Not authorized to send Apple events to Mail."
            return error.code == -1743 ? .notAllowed : .failed(error.message)
        }
        let answer = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let count = Int(answer) else { return .failed("Mail answered \"\(answer)\".") }
        return .marked(count)
    }
}
