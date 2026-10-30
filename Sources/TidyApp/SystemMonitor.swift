import AppKit
import Combine
import SwiftUI
import TidyCore

/// Samples CPU, memory and disk every two seconds, for the Performance screen and the menu bar.
@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var cpu: Double = 0
    @Published private(set) var memory: MemoryStats?
    @Published private(set) var disk: DiskSpace?

    private var lastTicks: CPUTicks?
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

    private func sample() {
        if let ticks = CPUTicks.current() {
            if let last = lastTicks {
                cpu = ticks.usage(since: last)
            }
            lastTicks = ticks
        }
        memory = MemoryStats.current()
        disk = DiskSpace.of()
    }
}

enum StatFormat {
    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }
    static func memory(_ value: UInt64) -> String { ByteFormat.memory(Int64(clamping: value)) }
}
