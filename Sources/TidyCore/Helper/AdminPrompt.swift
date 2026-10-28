import Foundation

/// Runs Tidy's own root commands after macOS asks for an administrator's password. It's for what the
/// admin helper doesn't do, and for builds that can't use the helper, which needs a Tidy.app signed
/// with a Developer ID (running from Xcode, or a Tidy.app signed ad hoc). Every run asks again.
/// Only commands Tidy puts together itself are run, every word quoted, and AppleScript gets the line
/// as data, never as script text.
public struct AdminPrompt: Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        /// The password prompt was cancelled, so nothing ran.
        case cancelled
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .cancelled: return "No password was entered, so nothing changed."
            case .failed(let message): return message
            }
        }
    }

    /// A program and its arguments. When a step that may fail does, the steps after it still run.
    public struct Step: Equatable, Sendable {
        public let command: [String]
        public let mayFail: Bool

        public init(_ command: [String], mayFail: Bool = false) {
            self.command = command
            self.mayFail = mayFail
        }
    }

    let osascript: URL

    public init(osascript: URL = URL(fileURLWithPath: "/usr/bin/osascript")) {
        self.osascript = osascript
    }

    /// The steps as one /bin/sh line, every word in single quotes. It stops at the first step that
    /// fails, unless that step may fail.
    public static func shellLine(_ steps: [Step]) -> String {
        steps.map { step in
            let command = step.command.map(quote).joined(separator: " ")
            return step.mayFail ? "{ \(command) || true; }" : command
        }
        .joined(separator: " && ")
    }

    /// The word in single quotes, so the shell reads it as it is, whatever it holds.
    static func quote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// osascript's arguments. The shell line and the prompt arrive as `argv`, so they're never read as AppleScript.
    static func arguments(_ steps: [Step], prompt: String) -> [String] {
        ["-e", "on run argv",
         "-e", "return do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges without altering line endings",
         "-e", "end run",
         shellLine(steps), prompt]
    }

    /// Asks for the password, then runs the steps as root and returns what they printed. It blocks
    /// until they're done, so call it off the main thread.
    @discardableResult
    public func run(_ steps: [Step], prompt: String) throws -> String {
        let result = try Subprocess.run(osascript, Self.arguments(steps, prompt: prompt))
        guard result.status != 0 else {
            // osascript ends the script's result with a line break of its own.
            return result.output.hasSuffix("\n") ? String(result.output.dropLast()) : result.output
        }
        let error = AppleScriptError(result.errors)
        // AppleScript's "User canceled."
        if error.code == -128 { throw Failure.cancelled }
        throw Failure.failed(error.message)
    }
}
