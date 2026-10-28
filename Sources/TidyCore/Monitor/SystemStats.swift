import Foundation

/// CPU time since boot, summed over all cores, in scheduler ticks. The counters wrap around.
public struct CPUTicks: Equatable, Sendable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    /// Share of time the CPU was busy between an earlier reading and this one, from 0 to 1.
    public func usage(since earlier: CPUTicks) -> Double {
        let busy = UInt64(user &- earlier.user) + UInt64(system &- earlier.system) + UInt64(nice &- earlier.nice)
        let total = busy + UInt64(idle &- earlier.idle)
        return total == 0 ? 0 : Double(busy) / Double(total)
    }
}

/// Page counts from the kernel's virtual memory statistics.
public struct VMPageCounts: Equatable, Sendable {
    public var free: UInt64 = 0
    public var active: UInt64 = 0
    public var inactive: UInt64 = 0
    public var speculative: UInt64 = 0
    public var wired: UInt64 = 0
    /// Pages the compressor occupies.
    public var compressed: UInt64 = 0
    public var purgeable: UInt64 = 0
    /// Pages holding file contents (cached files).
    public var fileBacked: UInt64 = 0
    /// Pages holding app data.
    public var anonymous: UInt64 = 0

    public init() {}
}

public enum MemoryPressure: Int, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4
}

/// Memory use as Activity Monitor reports it, in bytes.
public struct MemoryStats: Equatable, Sendable {
    public let total: UInt64
    public let app: UInt64
    public let wired: UInt64
    public let compressed: UInt64
    /// File contents kept in memory; macOS frees it as soon as apps need the space.
    public let cached: UInt64
    public let pressure: MemoryPressure

    public init(total: UInt64, pageSize: UInt64, pages: VMPageCounts, pressure: MemoryPressure = .normal) {
        self.total = total
        app = (pages.anonymous - min(pages.anonymous, pages.purgeable)) * pageSize
        wired = pages.wired * pageSize
        compressed = pages.compressed * pageSize
        cached = (pages.fileBacked + pages.purgeable) * pageSize
        self.pressure = pressure
    }

    public var used: UInt64 { app + wired + compressed }
    public var usedFraction: Double { total == 0 ? 0 : min(1, Double(used) / Double(total)) }
}

/// Free and total space of a volume, in bytes.
public struct DiskSpace: Equatable, Sendable {
    public let total: Int64
    /// Includes purgeable space macOS can free on demand.
    public let available: Int64

    public init(total: Int64, available: Int64) {
        self.total = total
        self.available = min(max(0, available), total)
    }

    public var used: Int64 { total - available }
    public var usedFraction: Double { total <= 0 ? 0 : Double(used) / Double(total) }

    /// The volume that holds `url`, the startup disk by default.
    public static func of(_ url: URL = URL(fileURLWithPath: "/")) -> DiskSpace? {
        #if os(macOS)
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return DiskSpace(total: Int64(total), available: available)
        #else
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity
        else { return nil }
        return DiskSpace(total: Int64(total), available: Int64(available))
        #endif
    }
}

/// Bytes an interface has received and sent since it came up. The counters are 32-bit and wrap.
public struct InterfaceCounters: Equatable, Sendable {
    public var received: UInt32
    public var sent: UInt32

    public init(received: UInt32, sent: UInt32) {
        self.received = received
        self.sent = sent
    }
}

public struct NetworkRate: Equatable, Sendable {
    public let receivedPerSecond: Double
    public let sentPerSecond: Double

    public static let zero = NetworkRate(receivedPerSecond: 0, sentPerSecond: 0)

    public init(receivedPerSecond: Double, sentPerSecond: Double) {
        self.receivedPerSecond = receivedPerSecond
        self.sentPerSecond = sentPerSecond
    }

    /// Throughput between two readings taken `seconds` apart. Interfaces missing from either one are ignored.
    public init(from earlier: [String: InterfaceCounters], to later: [String: InterfaceCounters], seconds: Double) {
        var received: UInt64 = 0
        var sent: UInt64 = 0
        for (name, now) in later {
            guard let before = earlier[name] else { continue }
            received += UInt64(now.received &- before.received)
            sent += UInt64(now.sent &- before.sent)
        }
        let seconds = max(seconds, 0.001)
        self.init(receivedPerSecond: Double(received) / seconds, sentPerSecond: Double(sent) / seconds)
    }
}

/// One reading of a process's resource use.
public struct ProcessSample: Equatable, Sendable {
    public let pid: Int32
    public let name: String
    /// CPU time used since the process started, in nanoseconds.
    public let cpuTime: UInt64
    /// Memory as Activity Monitor shows it (physical footprint), in bytes.
    public let memory: UInt64

    public init(pid: Int32, name: String, cpuTime: UInt64, memory: UInt64) {
        self.pid = pid
        self.name = name
        self.cpuTime = cpuTime
        self.memory = memory
    }
}

public struct ProcessLoad: Identifiable, Equatable, Sendable {
    public let pid: Int32
    public let name: String
    /// Percent of one core, so a process busy on several cores can pass 100.
    public let cpuPercent: Double
    public let memory: UInt64

    public var id: Int32 { pid }

    /// CPU use between two readings `seconds` apart, busiest first, then by memory. Processes that are
    /// new in the later reading (including a reused process ID) count as idle until the next one.
    public static func compare(_ earlier: [ProcessSample], _ later: [ProcessSample], seconds: Double) -> [ProcessLoad] {
        let before = Dictionary(earlier.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let nanoseconds = max(seconds, 0.001) * 1e9
        return later.map { sample in
            var percent = 0.0
            if let old = before[sample.pid], old.name == sample.name, sample.cpuTime >= old.cpuTime {
                percent = Double(sample.cpuTime - old.cpuTime) / nanoseconds * 100
            }
            return ProcessLoad(pid: sample.pid, name: sample.name, cpuPercent: percent, memory: sample.memory)
        }
        .sorted { ($0.cpuPercent, $0.memory) > ($1.cpuPercent, $1.memory) }
    }

    /// The ones using a lot right now: at least `cpuPercent` of one core, or `memory` bytes. Keeps the order.
    public static func heavy(_ loads: [ProcessLoad], cpuPercent: Double = 30, memory: UInt64 = 1_000_000_000) -> [ProcessLoad] {
        loads.filter { $0.cpuPercent >= cpuPercent || $0.memory >= memory }
    }
}
