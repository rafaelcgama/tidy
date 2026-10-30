import AppKit
import Combine
import SwiftUI
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

/// Check for Updates…, for the Tidy and Help menus: checks, and shows the answer in the Software Update window.
struct CheckForUpdatesButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Check for Updates…") {
            TidyUpdateModel.shared.check()
            openWindow(id: TidyUpdateWindow.id)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// The Software Update window, laid out like other Mac apps': what's new, and Install Update.
struct TidyUpdateWindow: View {
    static let id = "software-update"
    @ObservedObject var model: TidyUpdateModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(width: 380, alignment: .leading)
        }
        .padding(20)
    }

    /// The window is the key one when its button is clicked; `dismiss` only closes windows from macOS 14 on.
    private func close() {
        NSApp.keyWindow?.close()
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .checking:
            Text("Checking for updates…")
                .font(.headline)
            ProgressView()
                .progressViewStyle(.linear)
        case .downloading, .installing:
            Text(model.phase == .downloading ? "Downloading update…" : "Installing update…")
                .font(.headline)
            ProgressView()
                .progressViewStyle(.linear)
            Text("Tidy will quit and open again when it's done.")
                .foregroundStyle(.secondary)
        case .idle:
            if let error = model.errorMessage {
                Text("Something went wrong")
                    .font(.headline)
                Text(error)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("OK") {
                        model.errorMessage = nil
                        close()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else if let release = model.available {
                Text("A new version of Tidy is available!")
                    .font(.headline)
                Text("Tidy \(release.version) is now available. You have \(model.installedVersion ?? "a development copy"). Would you like to install it now?")
                    .fixedSize(horizontal: false, vertical: true)
                if !release.notes.isEmpty {
                    Text("Release Notes:")
                        .bold()
                    ScrollView {
                        Text(release.notes)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 140)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                }
                if !model.canInstall {
                    Text("Only the Tidy installed in Applications can update itself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Remind Me Later") { close() }
                    Spacer()
                    Button("Install Update") { model.install() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canInstall)
                }
            } else {
                Text("You're up to date!")
                    .font(.headline)
                Text("Tidy \(model.installedVersion ?? "") is the newest version available.")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("OK") { close() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}
