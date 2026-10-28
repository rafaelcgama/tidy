import AppKit
import SwiftUI
import TidyCore

/// The text shown in the menu bar.
struct MenuBarLabel: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        Text("CPU \(StatFormat.percent(monitor.cpu))  MEM \(StatFormat.percent(monitor.memory?.usedFraction ?? 0))")
            .monospacedDigit()
    }
}

/// The panel that opens from the menu bar.
struct MenuBarMonitorView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var reminders: ReminderModel
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
            row("CPU", StatFormat.percent(monitor.cpu))
            Sparkline(values: monitor.cpuHistory)
                .frame(height: 30)
            if let memory = monitor.memory {
                row("Memory", "\(StatFormat.bytes(memory.used)) of \(StatFormat.bytes(memory.total))")
                ProgressView(value: memory.usedFraction)
                    .tint(memory.pressure == .normal ? Color.accentColor : Color.orange)
            }
            if let disk = monitor.disk {
                row("Startup Disk", "\(ByteFormat.string(disk.available)) free")
                ProgressView(value: disk.usedFraction)
            }
            row("Network", "↓ \(StatFormat.rate(monitor.network.receivedPerSecond))  ↑ \(StatFormat.rate(monitor.network.sentPerSecond))")
            Divider()
            Text("Busiest")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(monitor.processes.prefix(5)) { process in
                HStack {
                    Text(monitor.app(for: process.pid)?.localizedName ?? process.name)
                        .lineLimit(1)
                    Spacer()
                    Text(String(format: "%.0f%%", process.cpuPercent))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            Divider()
            HStack {
                Button("Open Tidy") { showMainWindow() }
                Spacer()
                Button("Quit Tidy") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { monitor.watchProcesses() }
        .onDisappear { monitor.stopWatchingProcesses() }
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
