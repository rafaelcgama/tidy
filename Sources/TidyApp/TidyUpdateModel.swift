import AppKit
import Combine
import TidyCore

/// Updates Tidy itself from the releases GitHub builds from main. It checks once when Tidy starts and
/// when you ask; it only installs when you click Update Tidy.
@MainActor
final class TidyUpdateModel: ObservableObject {
    static let shared = TidyUpdateModel()

    enum Phase: Equatable {
        case idle
        case checking
        case downloading
        case installing
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var latest: TidyRelease?
    @Published private(set) var hasChecked = false
    @Published var errorMessage: String?

    let installedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let installedBuild = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init)

    /// The newer release, if there is one.
    var available: TidyRelease? {
        guard let latest, latest.isNewer(thanBuild: installedBuild) else { return nil }
        return latest
    }

    /// Run from Xcode or `swift run`, Tidy isn't an app in a folder it could replace.
    var canInstall: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && installedBuild != nil
    }

    /// The check when Tidy starts is quiet: if GitHub can't be reached then, nothing is said.
    func check(quietly: Bool = false) {
        guard phase == .idle else { return }
        phase = .checking
        Task {
            do {
                latest = try await TidyRelease.latest()
            } catch where !quietly {
                errorMessage = "Couldn't check for a new Tidy: \(error.localizedDescription)"
            } catch {}
            hasChecked = true
            phase = .idle
        }
    }

    /// Downloads the disk image, checks the app in it, puts it in place of this one once Tidy has
    /// quit, and opens it again.
    func install() {
        guard let release = available, canInstall, phase == .idle else { return }
        phase = .downloading
        Task {
            do {
                var request = URLRequest(url: release.downloadURL)
                request.timeoutInterval = 120
                let (download, _) = try await URLSession.shared.download(for: request)
                phase = .installing
                let current = Bundle.main.bundleURL
                let staged = try await Task.detached {
                    try TidyInstaller.stage(diskImage: download, expectedBuild: release.build, replacing: current)
                }.value
                try TidyInstaller.replaceAfterQuit(current: current, with: staged)
                NSApp.terminate(nil)
            } catch {
                errorMessage = "Couldn't update Tidy: \(error.localizedDescription)"
                phase = .idle
            }
        }
    }

    func openReleasePage() {
        NSWorkspace.shared.open(latest?.pageURL ?? URL(string: "https://github.com/\(TidyRelease.repository)/releases")!)
    }
}

/// The steps that swap the app for the downloaded one.
enum TidyInstaller {
    struct Failure: Error, LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Opens the disk image, checks that the Tidy.app inside is the expected, intact build, and copies
    /// it next to the running app (same disk, so the swap is a rename). Returns the copy.
    static func stage(diskImage: URL, expectedBuild: Int, replacing current: URL) throws -> URL {
        let folder = current.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw Failure("Tidy can't write to \(folder.path). Download Tidy.dmg from the release page and install it by hand.")
        }
        let mountPoint = FileManager.default.temporaryDirectory.appendingPathComponent("tidy-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", diskImage.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path])
        defer {
            _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
            try? FileManager.default.removeItem(at: mountPoint)
            try? FileManager.default.removeItem(at: diskImage)
        }
        let app = mountPoint.appendingPathComponent("Tidy.app")
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init) == expectedBuild
        else { throw Failure("The download isn't the Tidy build it should be, so nothing was changed.") }
        // A damaged or altered app fails its code signature check.
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let staged = folder.appendingPathComponent(".Tidy-update.app")
        try? FileManager.default.removeItem(at: staged)
        try run("/usr/bin/ditto", [app.path, staged.path])
        return staged
    }

    /// Starts a small shell that waits for Tidy to quit, swaps the apps and opens the new one.
    static func replaceAfterQuit(current: URL, with staged: URL) throws {
        let script = #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; rm -rf "$2" && mv "$3" "$2" && open "$2""#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), current.path, staged.path]
        try process.run()
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw Failure("\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(text.isEmpty ? "exit code \(process.terminationStatus)" : text)")
        }
        return text
    }
}
