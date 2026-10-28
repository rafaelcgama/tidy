import Foundation

/// Runs a program and waits for it, keeping what it printed.
public enum Subprocess {
    public struct Result: Sendable {
        public let status: Int32
        public let output: String
        public let errors: String
    }

    /// Blocks until the program exits, so call it off the main thread.
    public static func run(_ executable: URL, _ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // Standard output is read to the end first: the programs Tidy runs print little to standard error.
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        let complaints = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus,
                      output: String(decoding: printed, as: UTF8.self),
                      errors: String(decoding: complaints, as: UTF8.self))
    }
}

/// What osascript prints when a script fails, such as "0:94: execution error: User canceled. (-128)".
struct AppleScriptError: Equatable {
    let message: String
    let code: Int?

    init(_ text: String) {
        var message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = message.range(of: "execution error: ") {
            message = String(message[range.upperBound...])
        }
        var code: Int?
        if let range = message.range(of: #"\s*\(-?[0-9]+\)$"#, options: .regularExpression) {
            code = Int(message[range].trimmingCharacters(in: CharacterSet(charactersIn: " ()\t\n")))
            message.removeSubrange(range)
        }
        self.message = message.isEmpty ? "The script didn't finish." : message
        self.code = code
    }
}
