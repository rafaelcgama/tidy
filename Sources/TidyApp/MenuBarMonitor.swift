import AppKit
import SwiftUI
import TidyCore

/// The text shown in the menu bar.
struct MenuBarLabel: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        Text("CPU \(StatFormat.percent(monitor.cpu))  RAM \(StatFormat.percent(monitor.memory?.usedFraction ?? 0))")
            .monospacedDigit()
    }
}

/// The panel that opens from the menu bar.
struct MenuBarMonitorView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var reminders: ReminderModel
    @ObservedObject var tidy = TidyUpdateModel.shared
    let navigation: AppNavigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(reminders.due) { due in
                VStack(alignment: .leading, spacing: 6) {
                    Text(due.text)
                    Button(due.scan == .malware ? "Open Malware Scan" : "Open Smart Care") {
                        navigation.module = due.scan == .malware ? .malware : .smartCare
                        showMainWindow()
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
            }
            if let release = tidy.available {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tidy \(release.version) is available.")
                    Button("Update Tidy…") {
                        openWindow(id: TidyUpdateWindow.id)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
            }
            // The same three as the Performance screen, each a number and a bar.
            row("CPU", "\(StatFormat.percent(monitor.cpu)) used")
            ProgressView(value: min(max(monitor.cpu, 0), 1))
            if let memory = monitor.memory {
                row("RAM", "\(StatFormat.memory(memory.used)) used of \(StatFormat.memory(memory.total))")
                ProgressView(value: memory.usedFraction)
                    .tint(tint(for: memory))
            }
            if let disk = monitor.disk {
                row("Hard Drive", "\(ByteFormat.string(disk.available)) free of \(ByteFormat.string(disk.total))")
                ProgressView(value: disk.usedFraction)
            }
            Divider()
            HStack {
                Button("Open Tidy") { showMainWindow() }
                Spacer()
                // Tidy has no menus of its own while it lives in the menu bar, so their items are here.
                Menu {
                    SettingsButton()
                    CheckForUpdatesButton()
                    Divider()
                    TidyHelpButton()
                    AboutTidyButton()
                } label: {
                    Image(systemName: "gearshape")
                }
                .fixedSize()
                Button("Quit Tidy") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    /// Orange or red when macOS is short of memory, as on the Performance screen.
    private func tint(for memory: MemoryStats) -> Color {
        switch memory.pressure {
        case .warning: return .orange
        case .critical: return .red
        default: return .accentColor
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .fontWeight(.medium)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// Brings the main window forward, or opens it again if it was closed.
    private func showMainWindow() {
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
