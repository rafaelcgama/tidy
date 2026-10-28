#if os(macOS)
import Darwin
import Foundation

/// Asking for the host port adds a reference each time, so it is fetched once.
private let machHost = mach_host_self()

extension CPUTicks {
    /// The counters right now, or nil if the kernel refuses.
    public static func current() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(machHost, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        return CPUTicks(user: ticks.0, system: ticks.1, idle: ticks.2, nice: ticks.3)
    }
}

extension MemoryStats {
    public static func current() -> MemoryStats? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(machHost, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pages = VMPageCounts()
        pages.free = UInt64(info.free_count)
        pages.active = UInt64(info.active_count)
        pages.inactive = UInt64(info.inactive_count)
        pages.speculative = UInt64(info.speculative_count)
        pages.wired = UInt64(info.wire_count)
        pages.compressed = UInt64(info.compressor_page_count)
        pages.purgeable = UInt64(info.purgeable_count)
        pages.fileBacked = UInt64(info.external_page_count)
        pages.anonymous = UInt64(info.internal_page_count)
        return MemoryStats(total: ProcessInfo.processInfo.physicalMemory, pageSize: UInt64(vm_kernel_page_size),
                           pages: pages, pressure: currentPressure())
    }

    private static func currentPressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return MemoryPressure(rawValue: Int(level)) ?? .normal
    }
}

extension InterfaceCounters {
    /// Counters of the Ethernet and Wi-Fi interfaces (en0, en1…), by name.
    public static func current() -> [String: InterfaceCounters] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [:] }
        defer { freeifaddrs(list) }
        var counters: [String: InterfaceCounters] = [:]
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self).pointee
            else { continue }
            let name = String(cString: entry.ifa_name)
            if name.hasPrefix("en") {
                counters[name] = InterfaceCounters(received: data.ifi_ibytes, sent: data.ifi_obytes)
            }
        }
        return counters
    }
}

extension ProcessSample {
    /// Every process this user may inspect. Processes of root and other users are left out.
    public static func all() -> [ProcessSample] {
        let capacity = Int(proc_listallpids(nil, 0)) + 32
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        var samples: [ProcessSample] = []
        for pid in pids.prefix(min(count, capacity)) where pid > 0 {
            var usage = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard status == 0 else { continue }
            var nameBuffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let name = String(cString: nameBuffer)
            // CPU times are in Mach time units, which are not nanoseconds on Apple silicon.
            let cpuTime = (usage.ri_user_time + usage.ri_system_time) * UInt64(timebase.numer) / UInt64(max(1, timebase.denom))
            samples.append(ProcessSample(pid: pid, name: name.isEmpty ? "Process \(pid)" : name,
                                         cpuTime: cpuTime, memory: usage.ri_phys_footprint))
        }
        return samples
    }
}
#endif
