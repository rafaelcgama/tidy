import AppKit
import Combine
import SwiftUI
import TidyCore

/// Samples CPU, memory, disk and network every two seconds, for the Performance screen and the menu bar.
@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var cpu: Double = 0
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memory: MemoryStats?
    @Published private(set) var disk: DiskSpace?
    @Published private(set) var network = NetworkRate.zero
    @Published private(set) var processes: [ProcessLoad] = []

    nonisolated static let historyLength = 60

    private var lastTicks: CPUTicks?
    private var lastInterfaces: [String: InterfaceCounters] = [:]
    private var lastProcesses: [ProcessSample] = []
    private var lastSample = Date()
    private var processWatchers = 0
    private var timer: Timer?

    init() {
        sample()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        // Common modes keep it ticking while a menu is open or a list is scrolling.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Reading every process costs more, so it only happens while a screen shows the list.
    func watchProcesses() {
        processWatchers += 1
        if processWatchers == 1 { sampleProcesses(seconds: 0) }
    }

    func stopWatchingProcesses() {
        processWatchers = max(0, processWatchers - 1)
        if processWatchers == 0 {
            lastProcesses = []
            processes = []
        }
    }

    /// The app behind a process, when it is one (daemons and command-line tools aren't).
    func app(for pid: Int32) -> NSRunningApplication? {
        NSRunningApplication(processIdentifier: pid)
    }

    private func sample() {
        let now = Date()
        let seconds = now.timeIntervalSince(lastSample)
        lastSample = now
        if let ticks = CPUTicks.current() {
            if let last = lastTicks {
                cpu = ticks.usage(since: last)
                cpuHistory = Array((cpuHistory + [cpu]).suffix(Self.historyLength))
            }
            lastTicks = ticks
        }
        memory = MemoryStats.current()
        disk = DiskSpace.of()
        let interfaces = InterfaceCounters.current()
        if !lastInterfaces.isEmpty {
            network = NetworkRate(from: lastInterfaces, to: interfaces, seconds: seconds)
        }
        lastInterfaces = interfaces
        if processWatchers > 0 { sampleProcesses(seconds: seconds) }
    }

    private func sampleProcesses(seconds: Double) {
        let current = ProcessSample.all()
        processes = ProcessLoad.compare(lastProcesses, current, seconds: seconds)
        lastProcesses = current
    }
}

enum StatFormat {
    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }
    static func bytes(_ value: UInt64) -> String { ByteFormat.string(Int64(clamping: value)) }
    static func rate(_ bytesPerSecond: Double) -> String { ByteFormat.string(Int64(bytesPerSecond.rounded())) + "/s" }
}

/// Recent values between 0 and 1 as a line, newest on the right.
struct Sparkline: View {
    let values: [Double]
    var capacity = SystemMonitor.historyLength

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                guard values.count > 1 else { return }
                let step = proxy.size.width / CGFloat(max(1, capacity - 1))
                let start = proxy.size.width - step * CGFloat(values.count - 1)
                for (index, value) in values.enumerated() {
                    let y = proxy.size.height * (1 - CGFloat(min(max(value, 0), 1)))
                    let point = CGPoint(x: start + step * CGFloat(index), y: y)
                    if index == 0 {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
            }
            .stroke(Color.accentColor, lineWidth: 1.5)
        }
    }
}
