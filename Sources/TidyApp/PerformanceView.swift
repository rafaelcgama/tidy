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

    private var tiles: some View {
        HStack(alignment: .top, spacing: 12) {
            StatTile(title: "CPU", value: StatFormat.percent(monitor.cpu),
                     detail: "Average over all cores", fraction: monitor.cpu) {
                Sparkline(values: monitor.cpuHistory)
                    .frame(height: 28)
            }
            StatTile(title: "Memory",
                     value: monitor.memory.map { "\(StatFormat.memory($0.used)) of \(StatFormat.memory($0.total))" } ?? "–",
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
        case .normal: return "Pressure normal · \(StatFormat.memory(memory.cached)) cached files"
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
