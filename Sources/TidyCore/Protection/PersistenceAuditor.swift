import Foundation

public struct Finding: Identifiable, Sendable {
    public enum Severity: Int, Comparable, Sendable {
        case notice, warning, danger

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The file the finding is about (a launch job's plist, or a policy file).
    public let url: URL
    public let title: String
    public let severity: Severity
    public let reasons: [String]

    public var id: String { url.path }
}

/// Heuristics for persistence that malware and adware commonly use. A finding is a reason to look,
/// not proof: nothing is removed without the user choosing it.
public struct PersistenceAuditor: Sendable {
    public init() {}

    /// Locations only temporary or shared files should live in; a launch job running from here is a red flag.
    static let suspiciousLocations = ["/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/", "/var/folders/", "/private/var/folders/", "/Users/Shared/"]
    static let interpreters: Set<String> = ["sh", "bash", "zsh", "python", "python3", "perl", "ruby", "osascript", "curl"]
    static let downloadOrDecodeHints = ["curl ", "wget ", "base64", "| sh", "|sh", "| bash", "eval ", "http://", "https://"]
    /// Homebrew and MacPorts build what they install without a developer's certificate, so their programs aren't signature-checked.
    static let packageManagerFolders = ["/opt/homebrew/", "/usr/local/Cellar/", "/usr/local/opt/", "/usr/local/Homebrew/", "/opt/local/"]

    public func audit(_ items: [LaunchItem], fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                      signature: (String) -> CodeSignature = CodeSignature.check) -> [Finding] {
        items.compactMap { item in
            var reasons: [String] = []
            var severity = Finding.Severity.notice

            if let program = item.program {
                if !program.hasPrefix("/") {
                    // Relative programs are resolved by launchd; nothing to check on disk.
                } else if !fileExists(program) {
                    reasons.append("Starts a program that no longer exists (\(program)); probably left over from an uninstalled app.")
                } else if !Self.isFromPackageManager(program) {
                    switch signature(program) {
                    case .notIdentified, .unsigned:
                        reasons.append("Its program isn't signed by a developer Apple knows, so nothing shows who made it.")
                        severity = max(severity, .warning)
                    case .broken:
                        reasons.append("Its program was changed after its developer signed it.")
                        severity = max(severity, .warning)
                    case .identified, .unknown:
                        break
                    }
                }
                if Self.suspiciousLocations.contains(where: { program.hasPrefix($0) }) {
                    reasons.append("Runs a program from a temporary or shared folder.")
                    severity = max(severity, .danger)
                }
                if program.split(separator: "/").dropLast().contains(where: { $0.hasPrefix(".") }) {
                    reasons.append("Runs a program from a hidden folder.")
                    severity = max(severity, .danger)
                }
                let tool = String(program.split(separator: "/").last ?? "")
                let commandLine = item.arguments.dropFirst().joined(separator: " ")
                if Self.interpreters.contains(tool), Self.downloadOrDecodeHints.contains(where: { commandLine.contains($0) }) {
                    reasons.append("Runs a script that downloads or decodes code (\(tool) \(commandLine.prefix(80))).")
                    severity = max(severity, .danger)
                }
            } else {
                reasons.append("Has no program to run.")
            }

            if item.label != item.url.deletingPathExtension().lastPathComponent, item.scope != .userAgent {
                reasons.append("Its name (\(item.label)) doesn't match its file name.")
                severity = max(severity, .warning)
            }

            guard !reasons.isEmpty else { return nil }
            if severity == .notice, reasons.count > 1 { severity = .warning }
            return Finding(url: item.url, title: item.label, severity: severity, reasons: reasons)
        }
        .sorted { ($0.severity, $1.title) > ($1.severity, $0.title) }
    }

    /// Whether a program is where Homebrew or MacPorts put it, following links such as /usr/local/bin's.
    static func isFromPackageManager(_ program: String) -> Bool {
        let path = URL(fileURLWithPath: program).resolvingSymlinksInPath().path
        return packageManagerFolders.contains { path.hasPrefix($0) }
    }
}

/// Browser settings forced by a policy file: a common way adware locks the search engine or home page.
public struct BrowserPolicyAuditor: Sendable {
    /// Policy domains of browsers that read managed preferences.
    static let browsers: [(domain: String, name: String)] = [
        ("com.google.Chrome", "Chrome"),
        ("com.brave.Browser", "Brave"),
        ("com.microsoft.Edge", "Edge"),
        ("company.thebrowser.Browser", "Arc"),
        ("com.apple.Safari", "Safari"),
    ]
    static let hijackKeys = ["DefaultSearchProviderSearchURL", "DefaultSearchProviderName", "HomepageLocation",
                             "RestoreOnStartupURLs", "NewTabPageLocation", "ExtensionInstallForcelist", "HomePage"]

    public let managedPreferences: URL

    public init(managedPreferences: URL = URL(fileURLWithPath: "/Library/Managed Preferences")) {
        self.managedPreferences = managedPreferences
    }

    /// Checks /Library/Managed Preferences and its per-user subfolders.
    public func audit() -> [Finding] {
        let fm = FileManager.default
        var folders = [managedPreferences]
        folders += ((try? fm.contentsOfDirectory(at: managedPreferences, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

        var findings: [Finding] = []
        for folder in folders {
            for browser in Self.browsers {
                let url = folder.appendingPathComponent(browser.domain + ".plist")
                guard let data = try? Data(contentsOf: url),
                      let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
                else { continue }
                let forced = Self.hijackKeys.filter { plist[$0] != nil }
                guard !forced.isEmpty else { continue }
                findings.append(Finding(url: url,
                                        title: "\(browser.name) settings are locked by a policy",
                                        severity: .warning,
                                        reasons: forced.map { "\($0) is set to \(String(describing: plist[$0]!).prefix(120))" }
                                            + ["If your company doesn't manage this Mac, remove the configuration profile in System Settings › Privacy & Security › Profiles."]))
            }
        }
        return findings
    }
}
