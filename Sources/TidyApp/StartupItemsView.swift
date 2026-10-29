import AppKit
import ServiceManagement
import SwiftUI
import TidyCore

/// What starts with your Mac, with switches: apps that open at login and background items.
struct StartupItems: View {
    @ObservedObject var model: OptimizationModel
    /// Reading the apps that open at login makes macOS ask once, so it waits for a click the first time.
    @AppStorage("readLoginApps") private var readLoginApps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            loginApps
            backgroundItems
        }
        .onAppear {
            if !model.hasLoaded { model.refresh() }
            if readLoginApps, model.loginAppsState == .notLoaded { model.loadLoginApps() }
        }
    }

    private var loginApps: some View {
        PerformanceSection(title: "Apps That Open at Login", symbol: "person.crop.circle.badge.checkmark") {
            switch model.loginAppsState {
            case .notLoaded:
                Text("Tidy reads this list from System Events, so macOS asks once whether Tidy may.")
                    .foregroundStyle(.secondary)
                Button("Show Apps That Open at Login") {
                    readLoginApps = true
                    model.loadLoginApps()
                }
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
            case .notAllowed:
                Text("macOS didn't let Tidy read the list. Turn on System Events for Tidy in System Settings › Privacy & Security › Automation, then try again.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Automation Settings") { model.openAutomationSettings() }
                    Button("Try Again") { model.loadLoginApps() }
                }
            case .failed(let message):
                Text("Tidy couldn't read the list: \(message)")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { model.loadLoginApps() }
            case .loaded:
                if model.loginApps.isEmpty {
                    Text("No apps open at login.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.loginApps) { entry in
                    SwitchRow(icon: NSWorkspace.shared.icon(forFile: entry.app.path),
                              title: entry.app.name,
                              detail: DisplayPath.folder(of: URL(fileURLWithPath: entry.app.path)),
                              isOn: entry.isOn,
                              busy: model.busy.contains(entry.app.id)) { model.set(entry.app, on: $0) }
                }
            }
            HStack {
                Text("Items apps add to macOS's own list are switched in System Settings › General › Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
                    .controlSize(.small)
            }
        }
    }

    private var backgroundItems: some View {
        PerformanceSection(title: "Background Items", symbol: "gearshape.2") {
            if !model.hasLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if model.jobs.isEmpty {
                Text("No background items besides macOS's own.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.jobs) { job in
                    SwitchRow(icon: model.appURL(of: job).map { NSWorkspace.shared.icon(forFile: $0.path) },
                              title: model.name(of: job),
                              detail: detail(of: job),
                              isOn: model.isOn(job),
                              busy: model.busy.contains(job.id)) { model.set(job, on: $0) }
                        .contextMenu {
                            Button("Show in Finder") { model.revealJob(job) }
                        }
                }
            }
            Text("Apps add these to update themselves, sync, or run helpers. Switching one off stops it now and keeps it from starting again; its files stay where they are."
                 + (model.systemJobCount > 0 ? " Items that run for the whole system ask for an administrator's password." : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detail(of job: LaunchItem) -> String {
        var parts: [String] = model.name(of: job) == job.label ? [] : [job.label]
        parts.append(job.scope == .daemon ? "Runs for the whole system" : "Runs when you log in")
        if job.keepAlive { parts.append("kept running") }
        return parts.joined(separator: " · ")
    }
}

/// A titled box, one per part of the Performance screen.
struct PerformanceSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.headline)
            VStack(alignment: .leading, spacing: 8, content: content)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
        }
    }
}

private struct SwitchRow: View {
    let icon: NSImage?
    let title: String
    let detail: String
    let isOn: Bool
    let busy: Bool
    let change: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(detail)
            }
            Spacer()
            if busy {
                ProgressView()
                    .controlSize(.small)
            }
            Toggle(title, isOn: Binding(get: { isOn }, set: change))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(busy)
        }
    }
}

/// Root-only maintenance: fixed commands, run by the admin helper, or after macOS asks for an
/// administrator's password when the helper isn't installed.
struct MaintenanceTasks: View {
    @ObservedObject private var helper = AdminHelper.shared
    @State private var running: MaintenanceTask?
    @State private var confirming: MaintenanceTask?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(MaintenanceTask.allCases) { task in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title)
                        Text(task.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if running == task {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Run") {
                        if task == .reindexSpotlight { confirming = task } else { run(task) }
                    }
                    .disabled(running != nil)
                }
            }
            Text(helper.isEnabled
                 ? "These need administrator rights, so Tidy's admin helper runs them."
                 : "These need administrator rights, so macOS asks for your password each time.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let message {
                Text(message)
                    .font(.caption)
            }
        }
        .confirmationDialog("Reindex Spotlight?", isPresented: confirmShown, presenting: confirming) { task in
            Button("Reindex") { run(task) }
        } message: { _ in
            Text("Spotlight rebuilds its index of your startup disk. Until it finishes, which can take a few hours, searches miss files and the Mac is busier than usual.")
        }
    }

    private var confirmShown: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    private func run(_ task: MaintenanceTask) {
        running = task
        message = nil
        Task {
            do {
                try await helper.run(task)
                message = "\(task.title): done."
            } catch AdminPrompt.Failure.cancelled {
                message = "\(task.title) didn't run: no password was entered."
            } catch {
                message = "\(task.title) didn't finish: \(error.localizedDescription)"
            }
            running = nil
        }
    }
}
