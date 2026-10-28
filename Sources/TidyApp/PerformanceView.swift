import AppKit
import SwiftUI
import TidyCore

struct PerformanceView: View {
    @ObservedObject var monitor: SystemMonitor
    @Binding var selection: Module?
    @AppStorage("showMenuBarMonitor") private var showMenuBarMonitor = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                tiles
                suggestions
                processList
                Suggestion(symbol: "bolt", tint: .accentColor,
                           text: "Switch off apps and background items that start with your Mac, and run maintenance tasks, in Optimization.",
                           actionTitle: "Open Optimization") { selection = .optimization }
            }
            .padding(16)
        }
        .navigationTitle("Performance")
        .toolbar {
            Toggle("Show in Menu Bar", isOn: $showMenuBarMonitor)
        }
        .onAppear { monitor.watchProcesses() }
        .onDisappear { monitor.stopWatchingProcesses() }
    }

    private var tiles: some View {
        HStack(alignment: .top, spacing: 12) {
            StatTile(title: "CPU", value: StatFormat.percent(monitor.cpu),
                     detail: "Average over all cores", fraction: monitor.cpu) {
                Sparkline(values: monitor.cpuHistory)
                    .frame(height: 28)
            }
            StatTile(title: "Memory",
                     value: monitor.memory.map { "\(StatFormat.bytes($0.used)) of \(StatFormat.bytes($0.total))" } ?? "–",
                     detail: memoryDetail, fraction: monitor.memory?.usedFraction) { EmptyView() }
            StatTile(title: "Startup Disk",
                     value: monitor.disk.map { "\(ByteFormat.string($0.available)) free" } ?? "–",
                     detail: monitor.disk.map { "of \(ByteFormat.string($0.total))" } ?? "",
                     fraction: monitor.disk?.usedFraction) { EmptyView() }
            StatTile(title: "Network", value: "↓ \(StatFormat.rate(monitor.network.receivedPerSecond))",
                     detail: "↑ \(StatFormat.rate(monitor.network.sentPerSecond))", fraction: nil) { EmptyView() }
        }
    }

    private var memoryDetail: String {
        guard let memory = monitor.memory else { return "" }
        switch memory.pressure {
        case .normal: return "Pressure normal · \(StatFormat.bytes(memory.cached)) cached files"
        case .warning: return "Pressure high"
        case .critical: return "Pressure critical"
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

    private var processList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Busiest Processes")
                .font(.headline)
            if monitor.processes.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(monitor.processes.prefix(12)) { process in
                    ProcessRow(process: process, app: monitor.app(for: process.pid))
                    Divider()
                }
                Text("CPU is a percentage of one core, so busy apps can pass 100%. Processes of other users and the system aren't listed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct StatTile<Extra: View>: View {
    let title: String
    let value: String
    let detail: String
    let fraction: Double?
    @ViewBuilder let extra: () -> Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.bold())
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let fraction {
                ProgressView(value: min(max(fraction, 0), 1))
            }
            extra()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
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

struct ProcessRow: View {
    let process: ProcessLoad
    let app: NSRunningApplication?

    var body: some View {
        HStack(spacing: 10) {
            if let icon = app?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "gearshape")
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.secondary)
            }
            Text(app?.localizedName ?? process.name)
                .lineLimit(1)
            Spacer()
            Text(String(format: "%.1f%%", process.cpuPercent))
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
            Text(StatFormat.bytes(process.memory))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            if let app, app.activationPolicy == .regular, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                Button("Quit") { app.terminate() }
                    .help("Quits the app the normal way; it asks to save anything unsaved.")
            } else {
                Color.clear.frame(width: 44, height: 1)
            }
        }
    }
}
