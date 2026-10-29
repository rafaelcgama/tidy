import AppKit
import SwiftUI
import TidyCore

/// How busy the Mac is, the switches for what starts with it, and the maintenance tasks, in one place.
struct PerformanceView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var model: OptimizationModel
    @Binding var selection: Module?
    @AppStorage("showMenuBarMonitor") private var showMenuBarMonitor = true
    @AppStorage("readLoginApps") private var readLoginApps = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                tiles
                suggestions
                Text("Fewer things starting with your Mac means a faster startup and more free memory all day. Switching something off doesn't delete it: switch it back on any time.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                StartupItems(model: model)
                PerformanceSection(title: "Maintenance", symbol: "wrench.and.screwdriver") {
                    MaintenanceTasks()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Performance")
        .toolbar {
            Toggle("Show in Menu Bar", isOn: $showMenuBarMonitor)
            Button("Refresh") {
                model.refresh()
                if readLoginApps { model.loadLoginApps() }
            }
            .disabled(model.isLoading)
        }
        .alert("Something went wrong", isPresented: errorShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    /// Three boxes of the same height, each read live from macOS; click one to see more in Activity Monitor or Finder.
    private var tiles: some View {
        HStack(alignment: .top, spacing: 12) {
            StatTile(title: "CPU", opens: "Activity Monitor",
                     value: "\(StatFormat.percent(monitor.cpu)) used",
                     detail: "of \(ProcessInfo.processInfo.activeProcessorCount) cores",
                     fraction: monitor.cpu) { ActivityMonitor.open(.cpu) }
            StatTile(title: "RAM", opens: "Activity Monitor",
                     value: monitor.memory.map { "\(StatFormat.memory($0.used)) used" } ?? "–",
                     detail: monitor.memory.map { "of \(StatFormat.memory($0.total))" } ?? "",
                     fraction: monitor.memory?.usedFraction, tint: memoryTint,
                     exact: monitor.memory.map { "\($0.total.formatted()) bytes of RAM, as macOS reports it" }) { ActivityMonitor.open(.memory) }
            StatTile(title: "Hard Drive", opens: "Finder",
                     value: monitor.disk.map { "\(ByteFormat.string($0.available)) free" } ?? "–",
                     detail: monitor.disk.map { "of \(ByteFormat.string($0.total))" } ?? "",
                     fraction: monitor.disk?.usedFraction,
                     exact: monitor.disk.map { "\($0.total.formatted()) bytes on the startup disk, as macOS reports it" }) {
                NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The bar turns orange or red when macOS is short of memory, like Activity Monitor's pressure graph.
    private var memoryTint: Color? {
        switch monitor.memory?.pressure {
        case .warning: return .orange
        case .critical: return .red
        default: return nil
        }
    }

    @ViewBuilder
    private var suggestions: some View {
        if let memory = monitor.memory, memory.pressure != .normal {
            Suggestion(symbol: "memorychip", tint: memory.pressure == .critical ? .red : .orange,
                       text: "Memory is running short, so macOS is compressing and swapping. Quitting apps you aren't using will speed things up.")
        }
        if let disk = monitor.disk, disk.usedFraction > 0.9 {
            Suggestion(symbol: "internaldrive", tint: .orange,
                       text: "Your startup disk is almost full, which slows macOS down.",
                       actionTitle: "Free Up Space…") { selection = .smartCare }
        }
    }
}

private struct StatTile: View {
    let title: String
    let opens: String
    let value: String
    let detail: String
    let fraction: Double?
    var tint: Color?
    var exact: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                    Spacer()
                    Text("\(opens) ›")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.bold())
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                ProgressView(value: min(max(fraction ?? 0, 0), 1))
                    .tint(tint)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(exact ?? "")
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(opens)")
    }
}

/// Opens Activity Monitor on the CPU or Memory tab. It reads the tab to show from its own settings when it
/// starts, so this only picks the tab if Activity Monitor isn't already open.
enum ActivityMonitor {
    enum Tab: Int { case cpu = 0, memory = 1 }

    static func open(_ tab: Tab) {
        let id = "com.apple.ActivityMonitor"
        if NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
            UserDefaults(suiteName: id)?.set(tab.rawValue, forKey: "SelectedTab")
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

private struct Suggestion: View {
    let symbol: String
    let tint: Color
    let text: String
    var actionTitle: String?
    var action: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundColor(tint)
                .font(.title3)
            Text(text)
            Spacer()
            if let actionTitle {
                Button(actionTitle, action: action)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.1)))
    }
}
