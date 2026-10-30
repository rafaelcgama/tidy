import AppKit
import Combine
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
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutTidyButton()
                CheckForUpdatesButton()
            }
            CommandGroup(replacing: .help) {
                TidyHelpButton()
                Divider()
                AboutTidyButton()
                CheckForUpdatesButton()
            }
        }
        Window("Software Update", id: TidyUpdateWindow.id) {
            TidyUpdateWindow(model: TidyUpdateModel.shared)
        }
        .windowResizability(.contentSize)
        // Opened only from About Tidy in the Tidy and Help menus, not listed in the Window menu.
        Window("About Tidy", id: AboutTidyWindow.id) {
            AboutTidyWindow()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commandsRemoved()
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingChanges: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DockIcon.update()
        // Turning the menu bar monitor off in Settings or Performance puts Tidy in the Dock, and on takes it out.
        settingChanges = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { _ in DockIcon.update() }
        if DockIcon.menuBarMonitorShown && Self.openedAtLogin {
            // Opened at login: menu bar only. SwiftUI opens the main window as Tidy starts, by now or just
            // after this returns, so it's closed both times.
            DockIcon.closeWindows()
            DispatchQueue.main.async { DockIcon.closeWindows() }
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        // Batches past their retention period are deleted for good: the app's own here, the
        // admin helper's when it's contacted.
        _ = try? QuarantineStore(root: QuarantineStore.defaultRoot).purgeExpired()
        Task { @MainActor in
            AdminHelper.shared.checkIn()
            // Only finds out whether a newer Tidy exists; installing waits for your click.
            TidyUpdateModel.shared.check(quietly: true)
        }
    }

    /// With the menu bar monitor on, closing the window keeps Tidy running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !DockIcon.menuBarMonitorShown
    }

    /// Whether macOS opened Tidy as a login item (Open Tidy at login in Settings), rather than you opening it.
    /// Only known while Tidy starts.
    private static var openedAtLogin: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
}

/// With the menu bar monitor on, Tidy lives in the menu bar like other menu bar apps: no Dock icon and no menus,
/// even while its window is open; the panel's ⚙ menu has what the menus held. With it off, Tidy is an ordinary
/// app in the Dock. Info.plist's LSUIElement starts Tidy out of the Dock, so it doesn't show there even briefly.
@MainActor
enum DockIcon {
    nonisolated static var menuBarMonitorShown: Bool {
        UserDefaults.standard.object(forKey: "showMenuBarMonitor") as? Bool ?? true
    }

    /// Out of the Dock while the menu bar monitor is on, in it while it's off. Runs from Xcode or `swift run`
    /// have no app bundle and stay in the Dock as a plain program, which is handier while working on Tidy;
    /// they also need this to show their windows at all.
    static func update() {
        let inDock = !menuBarMonitorShown || Bundle.main.bundleIdentifier == nil
        let policy: NSApplication.ActivationPolicy = inDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    /// Closes Tidy's windows (main, Settings, Software Update, About), not the menu bar panel.
    static func closeWindows() {
        for window in NSApp.windows where !(window is NSPanel) && window.styleMask.contains(.titled) && window.level == .normal {
            window.close()
        }
    }
}
