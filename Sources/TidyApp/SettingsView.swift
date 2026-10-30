import AppKit
import ServiceManagement
import SwiftUI
import TidyCore

struct SettingsView: View {
    @ObservedObject var reminders: ReminderModel

    var body: some View {
        TabView {
            ReminderSettings(model: reminders)
                .tabItem { Label("Reminders", systemImage: "bell") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            HelperSettings()
                .tabItem { Label("Admin Helper", systemImage: "lock.shield") }
        }
        .padding(20)
        .frame(width: 480)
    }
}

private struct ReminderSettings: View {
    @ObservedObject var model: ReminderModel

    private static let choices = [7, 14, 30, 90]

    var body: some View {
        Form {
            Text("Tidy never scans or updates anything on its own. It can remind you when your last scan is getting old; you start the scan yourself.")
                .fixedSize(horizontal: false, vertical: true)
            Section {
                row(.smartCare, title: "Remind me to run Smart Care")
            }
            Section {
                row(.malware, title: "Remind me to run a malware Quick Scan")
            }
            Text("A due reminder shows only inside Tidy, in Smart Care and in the menu bar panel. Tidy never sends notifications.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func row(_ scan: ScanReminders.Scan, title: String) -> some View {
        Toggle(title, isOn: Binding(get: { model.reminders[scan].isEnabled },
                                    set: { model.setEnabled($0, for: scan) }))
        Picker("When the last scan is older than", selection: Binding(get: { model.reminders[scan].days },
                                                                      set: { model.reminders[scan].days = $0 })) {
            ForEach(Self.choices, id: \.self) { days in
                Text(Self.label(days)).tag(days)
            }
        }
        .disabled(!model.reminders[scan].isEnabled)
        LabeledContent("Last scan", value: model.lastScanText(scan))
    }

    private static func label(_ days: Int) -> String {
        switch days {
        case 7: return "1 week"
        case 14: return "2 weeks"
        case 30: return "1 month"
        case 90: return "3 months"
        default: return "\(days) days"
        }
    }
}

private struct HelperSettings: View {
    @ObservedObject private var helper = AdminHelper.shared

    var body: some View {
        Form {
            Text("Some cleanup needs administrator rights: system caches and logs, and apps installed for all users and their background items. Without the helper, macOS asks for an administrator's password each time. With it, Tidy's admin helper does that work without asking: it stays in a short list of system folders, refuses anything macOS protects, and moves items to a quarantine you can undo, like everything else Tidy cleans.")
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Status") {
                Text(helper.statusText)
            }
            HStack {
                switch helper.status {
                case .notInstalled:
                    Button("Install Helper…") { helper.install() }
                case .needsApproval:
                    Button("Open Login Items Settings") { helper.openLoginItems() }
                    Button("Remove Helper") { helper.uninstall() }
                case .enabled:
                    Button("Remove Helper") { helper.uninstall() }
                case .unavailable:
                    EmptyView()
                }
            }
            if let error = helper.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { helper.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Approving the helper happens in System Settings, so check again on return.
            helper.refresh()
        }
    }
}

private struct GeneralSettings: View {
    @AppStorage("showMenuBarMonitor") private var showMenuBarMonitor = true
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Toggle("Show CPU and RAM in the menu bar", isOn: $showMenuBarMonitor)
            Toggle("Open Tidy at login", isOn: Binding(get: { opensAtLogin }, set: { setOpensAtLogin($0) }))
            if let loginError {
                Text(loginError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Cleaned items stay in quarantine for \(QuarantineStore(root: QuarantineStore.defaultRoot).retentionDays) days, then they're deleted for good.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func setOpensAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "macOS didn't allow it (\(error.localizedDescription)). This works once Tidy is installed as an app."
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}
