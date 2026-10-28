import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Turns launchd jobs off and on the way launchd records it (`launchctl disable` and `enable`), so
/// nothing is moved or deleted and a job that was switched off can always be switched back on.
public enum LaunchJobControl {
    public enum Failure: Error, Equatable, LocalizedError {
        case unusableLabel(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .unusableLabel(let label): return "Tidy doesn't pass the name \"\(label)\" to launchctl."
            case .failed(let message): return message
            }
        }
    }

    static let launchctl = "/bin/launchctl"

    /// The launchd domain a job runs in: agents in your login session, daemons in the system's.
    public static func domain(for scope: LaunchItem.Scope, uid: UInt32) -> String {
        scope == .daemon ? "system" : "gui/\(uid)"
    }

    /// Labels Tidy passes to launchctl: letters, digits and . _ - @ +, as reverse-DNS names use.
    public static func isUsableLabel(_ label: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@+")
        return !label.isEmpty && label.count <= 255 && !label.hasPrefix("-") && label.allSatisfy { allowed.contains($0) }
    }

    /// Switching a daemon runs launchctl as root, so macOS asks for an administrator's password.
    public static func needsAdmin(_ item: LaunchItem) -> Bool {
        item.scope == .daemon
    }

    /// What switches a job off (and stops it now) or on (and starts it now, if it starts at load).
    /// Stopping and starting may fail, when the job isn't running or is already loaded; the switch itself may not.
    public static func steps(for item: LaunchItem, on: Bool, uid: UInt32) throws -> [AdminPrompt.Step] {
        guard isUsableLabel(item.label) else { throw Failure.unusableLabel(item.label) }
        let domain = domain(for: item.scope, uid: uid)
        let service = domain + "/" + item.label
        if on {
            return [AdminPrompt.Step([launchctl, "enable", service]),
                    AdminPrompt.Step([launchctl, "bootstrap", domain, item.url.path], mayFail: true)]
        }
        return [AdminPrompt.Step([launchctl, "disable", service]),
                AdminPrompt.Step([launchctl, "bootout", service], mayFail: true)]
    }

    /// Runs steps as you (switching agents needs no password). A step that may not fail throws what launchctl said.
    public static func run(_ steps: [AdminPrompt.Step]) throws {
        for step in steps {
            guard let program = step.command.first else { continue }
            let result = try Subprocess.run(URL(fileURLWithPath: program), Array(step.command.dropFirst()))
            if result.status != 0, !step.mayFail {
                let message = result.errors.trimmingCharacters(in: .whitespacesAndNewlines)
                throw Failure.failed(message.isEmpty ? "launchctl stopped with exit code \(result.status)." : message)
            }
        }
    }

    // MARK: - Reading the switches

    /// launchd's switches in a domain, from `launchctl print-disabled`: true where a job is switched
    /// off. Jobs it doesn't list follow the Disabled key in their plist.
    public static func parseSwitches(_ output: String) -> [String: Bool] {
        var switches: [String: Bool] = [:]
        var inDisabledServices = false
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix("= {") {
                inDisabledServices = text.hasPrefix("disabled services")
                continue
            }
            if text == "}" {
                inDisabledServices = false
                continue
            }
            guard inDisabledServices, text.hasPrefix("\""), let arrow = text.range(of: "\" => ") else { continue }
            let label = String(text[text.index(after: text.startIndex)..<arrow.lowerBound])
            // Older macOS versions print true and false.
            switch text[arrow.upperBound...].trimmingCharacters(in: .whitespaces) {
            case "disabled", "true": switches[label] = true
            case "enabled", "false": switches[label] = false
            default: continue
            }
        }
        return switches
    }

    /// The switches in a domain; empty when launchctl isn't there or won't say.
    public static func switches(domain: String) -> [String: Bool] {
        guard let result = try? Subprocess.run(URL(fileURLWithPath: launchctl), ["print-disabled", domain]),
              result.status == 0 else { return [:] }
        return parseSwitches(result.output)
    }

    /// Whether a job starts when it's meant to. launchd's own switch wins over the plist's Disabled key.
    public static func isOn(_ item: LaunchItem, switches: [String: Bool]) -> Bool {
        !(switches[item.label] ?? item.disabled)
    }

    // MARK: - Removing and restoring agents

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
