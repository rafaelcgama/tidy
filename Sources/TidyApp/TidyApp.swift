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
    private var windowChanges: [AnyCancellable] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowChanges = DockIcon.follow()
        if DockIcon.menuBarMonitorShown && Self.openedAtLogin {
            // Opened at login: menu bar only. SwiftUI opens the main window as Tidy starts, by now or just
            // after this returns, so it's closed both times.
            DockIcon.closeWindows()
            DispatchQueue.main.async { DockIcon.closeWindows() }
        } else {
            // Tidy's window opens as it starts, so it starts in the Dock, with its menus.
            NSApp.setActivationPolicy(.regular)
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

/// Tidy is in the Dock, with its menus at the top of the screen, while one of its windows is open: macOS shows an
/// app's menus only while it's in the Dock. With the menu bar monitor on, closing the last window leaves Tidy only
/// in the menu bar, like other menu bar apps, and opening one brings the Dock icon and menus back. With it off,
/// closing the window quits Tidy. Info.plist's LSUIElement starts Tidy out of the Dock, so opening at login doesn't
/// show it there even briefly. Runs from Xcode or `swift run` have no app bundle and always stay in the Dock as a
/// plain program, which is handier while working on Tidy.
@MainActor
enum DockIcon {
    nonisolated static var menuBarMonitorShown: Bool {
        UserDefaults.standard.object(forKey: "showMenuBarMonitor") as? Bool ?? true
    }

    /// Follows Tidy's windows as they open and close, for as long as what it returns is kept.
    nonisolated static func follow() -> [AnyCancellable] {
        let center = NotificationCenter.default
        return [
            center.publisher(for: NSWindow.didBecomeKeyNotification).sink { note in
                guard let window = note.object as? NSWindow else { return }
                // Unless it was closed meanwhile, as when Tidy starts at login.
                Task { @MainActor in if window.isVisible && counts(window) { show() } }
            },
            // The task runs once the window is gone; while it closes, it still counts as open.
            center.publisher(for: NSWindow.willCloseNotification).sink { note in
                guard let window = note.object as? NSWindow else { return }
                Task { @MainActor in if counts(window) { hideIfNoWindows() } }
            },
        ]
    }

    /// Puts Tidy in the Dock, with its menus.
    static func show() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        // On the next turn, once macOS has taken in the change, so the menus come up with the window.
        Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
    }

    /// Closes Tidy's windows, which leaves it in the menu bar only.
    static func closeWindows() {
        for window in NSApp.windows where counts(window) {
            window.close()
        }
    }

    /// Out of the Dock, with the menu bar monitor on, once none of Tidy's windows is open.
    private static func hideIfNoWindows() {
        let open = NSApp.windows.contains { counts($0) && ($0.isVisible || $0.isMiniaturized) }
        guard menuBarMonitorShown, Bundle.main.bundleIdentifier != nil, !open else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Tidy's own windows (main, Settings, Software Update, About), not the menu bar panel, alerts or file pickers.
    private static func counts(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled) && window.level == .normal
    }
}
