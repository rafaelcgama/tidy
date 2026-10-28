import AppKit
import Combine
import TidyCore

/// What starts with your Mac: apps that open at login and background items (launchd jobs), with
/// switches that turn them off and back on. Nothing is moved or deleted.
@MainActor
final class OptimizationModel: ObservableObject {
    struct LoginAppRow: Identifiable {
        let app: LoginApp
        let isOn: Bool
        var id: String { app.id }
    }

    enum LoginAppsState: Equatable {
        case notLoaded
        case loading
        case loaded
        /// macOS didn't let Tidy ask System Events (Privacy & Security › Automation).
        case notAllowed
        case failed(String)
    }

    @Published private(set) var jobs: [LaunchItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var loginApps: [LoginAppRow] = []
    @Published private(set) var loginAppsState: LoginAppsState = .notLoaded
    /// Jobs and apps being switched right now.
    @Published private(set) var busy: Set<String> = []
    @Published var errorMessage: String?

    @Published private var userSwitches: [String: Bool] = [:]
    @Published private var systemSwitches: [String: Bool] = [:]
    private let loginItems = LoginApps()
    private let uid = UInt32(getuid())

    var systemJobCount: Int { jobs.filter(LaunchJobControl.needsAdmin).count }

    func refresh() {
        isLoading = true
        let uid = self.uid
        Task {
            let (jobs, user, system) = await Task.detached { () -> ([LaunchItem], [String: Bool], [String: Bool]) in
                // macOS's own jobs aren't listed: switching them off can break macOS.
                let jobs = LaunchItemReader.items(in: LaunchItemReader.defaultFolders()).filter { !$0.label.hasPrefix("com.apple.") }
                return (jobs,
                        LaunchJobControl.switches(domain: LaunchJobControl.domain(for: .userAgent, uid: uid)),
                        LaunchJobControl.switches(domain: LaunchJobControl.domain(for: .daemon, uid: uid)))
            }.value
            self.jobs = jobs.sorted { name(of: $0).localizedCaseInsensitiveCompare(name(of: $1)) == .orderedAscending }
            userSwitches = user
            systemSwitches = system
            isLoading = false
            hasLoaded = true
        }
    }

    func isOn(_ job: LaunchItem) -> Bool {
        LaunchJobControl.isOn(job, switches: job.scope == .daemon ? systemSwitches : userSwitches)
    }

    /// The app a job comes with, or its label.
    func name(of job: LaunchItem) -> String {
        job.appName ?? job.label
    }

    /// The app a job comes with, for its icon.
    func appURL(of job: LaunchItem) -> URL? {
        guard let program = job.program, let range = program.range(of: ".app/") else { return nil }
        return URL(fileURLWithPath: String(program[..<range.lowerBound]) + ".app")
    }

    /// Switches a job off (it stops now and doesn't start again) or back on. Switching a system item
    /// runs launchctl as root, so macOS asks for an administrator's password.
    func set(_ job: LaunchItem, on: Bool) {
        guard !busy.contains(job.id) else { return }
        let steps: [AdminPrompt.Step]
        do {
            steps = try LaunchJobControl.steps(for: job, on: on, uid: uid)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let title = name(of: job)
        let prompt = "Tidy needs an administrator's password to turn \(on ? "on" : "off") \(title)."
        busy.insert(job.id)
        Task {
            do {
                if LaunchJobControl.needsAdmin(job) {
                    _ = try await AdminHelper.runAsRoot(steps, prompt: prompt)
                    systemSwitches[job.label] = !on
                } else {
                    try await Task.detached { try LaunchJobControl.run(steps) }.value
                    userSwitches[job.label] = !on
                }
            } catch AdminPrompt.Failure.cancelled {
                // No password, so nothing changed.
            } catch {
                errorMessage = "\(title) wasn't turned \(on ? "on" : "off"): \(error.localizedDescription)"
            }
            busy.remove(job.id)
            refresh()
        }
    }

    func revealJob(_ job: LaunchItem) {
        NSWorkspace.shared.activateFileViewerSelecting([job.url])
    }

    // MARK: - Apps that open at login

    /// Reads the list through System Events; the first time, macOS asks whether Tidy may.
    func loadLoginApps() {
        if loginAppsState != .loaded { loginAppsState = .loading }
        let loginItems = self.loginItems
        Task {
            do {
                let list = try await Task.detached { try loginItems.list() }.value
                loginApps = (list.on.map { LoginAppRow(app: $0, isOn: true) } + list.off.map { LoginAppRow(app: $0, isOn: false) })
                    .sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
                loginAppsState = .loaded
            } catch LoginApps.Failure.notAllowed {
                loginAppsState = .notAllowed
            } catch {
                loginAppsState = .failed(error.localizedDescription)
            }
        }
    }

    /// Takes an app off the list of apps that open at login, or puts it back.
    func set(_ app: LoginApp, on: Bool) {
        guard !busy.contains(app.id) else { return }
        busy.insert(app.id)
        let loginItems = self.loginItems
        Task {
            do {
                try await Task.detached {
                    if on { try loginItems.turnOn(app) } else { try loginItems.turnOff(app) }
                }.value
            } catch LoginApps.Failure.notAllowed {
                loginAppsState = .notAllowed
            } catch {
                errorMessage = "\(app.name) wasn't turned \(on ? "on" : "off"): \(error.localizedDescription)"
            }
            busy.remove(app.id)
            loadLoginApps()
        }
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}
