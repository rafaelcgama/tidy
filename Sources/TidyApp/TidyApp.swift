import AppKit
import SwiftUI
import TidyCore

/// Starts Tidy. When macOS's password prompt started it as root for one request instead (see
/// AdminCommand), it does just that, prints the reply and exits, without any window.
@main
enum TidyMain {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count > 1, arguments[1] == AdminCommand.flag {
            let service = PrivilegedService(policy: HelperPolicy(protectedPaths: [Bundle.main.bundleURL.path]))
            let (output, status) = AdminCommand.handle(arguments, service: service) ?? ("", 64)
            let handle = status == 0 ? FileHandle.standardOutput : FileHandle.standardError
            handle.write(Data((output + "\n").utf8))
            exit(status)
        }
        TidyApp.main()
    }
}

struct TidyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = SystemMonitor()
    @StateObject private var reminders = ReminderModel.shared
    @StateObject private var navigation = AppNavigation()
    @AppStorage("showMenuBarMonitor") private var showMenuBarMonitor = true

    var body: some Scene {
        WindowGroup("Tidy", id: "main") {
            ContentView(monitor: monitor, reminders: reminders, navigation: navigation)
        }
        Settings {
            SettingsView(reminders: reminders)
        }
        MenuBarExtra(isInserted: $showMenuBarMonitor) {
            MenuBarMonitorView(monitor: monitor, reminders: reminders, navigation: navigation)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lets `swift run TidyApp` show a normal window and Dock icon before there is an app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Batches past their retention period are deleted for good: the app's own here, the
        // admin helper's when it's contacted.
        _ = try? QuarantineStore(root: QuarantineStore.defaultRoot).purgeExpired()
        Task { @MainActor in AdminHelper.shared.checkIn() }
    }

    /// With the menu bar monitor on, closing the window keeps Tidy running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(UserDefaults.standard.object(forKey: "showMenuBarMonitor") as? Bool ?? true)
    }
}
