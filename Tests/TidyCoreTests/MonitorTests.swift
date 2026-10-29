import XCTest
@testable import TidyCore

final class MonitorTests: XCTestCase {
    func testCPUUsageIsBusyShareOfElapsedTicks() {
        let earlier = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let later = CPUTicks(user: 200, system: 100, idle: 1700, nice: 0)
        XCTAssertEqual(later.usage(since: earlier), 0.15, accuracy: 1e-9)
        XCTAssertEqual(earlier.usage(since: earlier), 0, "no time passed")
    }

    func testCPUCountersThatWrapStillGiveTheRightUsage() {
        let earlier = CPUTicks(user: .max - 9, system: 0, idle: .max - 49, nice: 0)
        let later = CPUTicks(user: 40, system: 0, idle: 100, nice: 0)   // user +50, idle +150
        XCTAssertEqual(later.usage(since: earlier), 0.25, accuracy: 1e-9)
    }

    func testMemoryIsSplitLikeActivityMonitor() {
        var pages = VMPageCounts()
        pages.anonymous = 100_000
        pages.purgeable = 10_000
        pages.wired = 50_000
        pages.compressed = 20_000
        pages.fileBacked = 30_000
        let page: UInt64 = 16_384
        let stats = MemoryStats(total: 16 << 30, pageSize: page, pages: pages, pressure: .warning)
        XCTAssertEqual(stats.app, 90_000 * page)
        XCTAssertEqual(stats.wired, 50_000 * page)
        XCTAssertEqual(stats.compressed, 20_000 * page)
        XCTAssertEqual(stats.cached, 40_000 * page)
        XCTAssertEqual(stats.used, 160_000 * page)
        XCTAssertEqual(stats.usedFraction, Double(160_000 * page) / Double(16 << 30), accuracy: 1e-9)
        XCTAssertEqual(stats.pressure, .warning)

        pages.purgeable = 200_000   // more purgeable than anonymous pages must not underflow
        XCTAssertEqual(MemoryStats(total: 1, pageSize: page, pages: pages).app, 0)
        XCTAssertEqual(MemoryStats(total: 1, pageSize: page, pages: pages).usedFraction, 1, "capped at 100%")
    }

    func testNetworkRateHandlesWrapsAndNewInterfaces() {
        let earlier = ["en0": InterfaceCounters(received: .max - 999, sent: 1_000)]
        let later = ["en0": InterfaceCounters(received: 1_000, sent: 5_000),   // received +2000 across the wrap
                     "en1": InterfaceCounters(received: 9_999_999, sent: 9_999_999)]  // not in the earlier reading
        let rate = NetworkRate(from: earlier, to: later, seconds: 2)
        XCTAssertEqual(rate.receivedPerSecond, 1_000, accuracy: 1e-9)
        XCTAssertEqual(rate.sentPerSecond, 2_000, accuracy: 1e-9)
        XCTAssertEqual(NetworkRate(from: [:], to: later, seconds: 2), .zero)
    }

    func testProcessLoadComparesReadingsByPID() {
        let earlier = [ProcessSample(pid: 10, name: "Safari", cpuTime: 1_000_000_000, memory: 500),
                       ProcessSample(pid: 11, name: "old", cpuTime: 9_000_000_000, memory: 100)]
        let later = [ProcessSample(pid: 10, name: "Safari", cpuTime: 2_000_000_000, memory: 600),  // 1 s of CPU in 2 s
                     ProcessSample(pid: 11, name: "reused", cpuTime: 1, memory: 900),             // same PID, new process
                     ProcessSample(pid: 12, name: "new", cpuTime: 5_000_000_000, memory: 50)]
        let loads = ProcessLoad.compare(earlier, later, seconds: 2)
        XCTAssertEqual(loads.map(\.name), ["Safari", "reused", "new"], "busiest first, then by memory")
        XCTAssertEqual(loads[0].cpuPercent, 50, accuracy: 1e-9)
        XCTAssertEqual(loads[1].cpuPercent, 0)
        XCTAssertEqual(loads[2].cpuPercent, 0)
        XCTAssertEqual(loads[0].memory, 600)
    }

    func testHeavyProcessesUseALotOfCPUOrMemory() {
        let loads = [ProcessLoad(pid: 1, name: "busy", cpuPercent: 85, memory: 100),
                     ProcessLoad(pid: 2, name: "big", cpuPercent: 0, memory: 2_000_000_000),
                     ProcessLoad(pid: 3, name: "quiet", cpuPercent: 29.9, memory: 999_999_999)]
        XCTAssertEqual(ProcessLoad.heavy(loads).map(\.name), ["busy", "big"])
        XCTAssertEqual(ProcessLoad.heavy(loads, cpuPercent: 10, memory: .max).map(\.name), ["busy", "quiet"])
    }

    func testMemoryIsCountedLikeActivityMonitor() {
        // 16 GB of RAM is 17.18 billion bytes: memory counts 1,024 to the kilobyte, files and disks 1,000.
        XCTAssertTrue(ByteFormat.memory(17_179_869_184).hasPrefix("16"), ByteFormat.memory(17_179_869_184))
        XCTAssertTrue(ByteFormat.string(17_179_869_184).hasPrefix("17"), ByteFormat.string(17_179_869_184))
    }

    func testDiskSpace() throws {
        let disk = DiskSpace(total: 1_000, available: 250)
        XCTAssertEqual(disk.used, 750)
        XCTAssertEqual(disk.usedFraction, 0.75, accuracy: 1e-9)
        XCTAssertEqual(DiskSpace(total: 100, available: 500).available, 100, "never more free than total")
        if let real = DiskSpace.of(FileManager.default.temporaryDirectory) {
            XCTAssertGreaterThan(real.total, 0)
            XCTAssertLessThanOrEqual(real.available, real.total)
        }
    }

    #if os(macOS)
    func testReadersWorkOnThisMac() throws {
        let ticks = try XCTUnwrap(CPUTicks.current())
        XCTAssertGreaterThan(UInt64(ticks.user) + UInt64(ticks.system) + UInt64(ticks.idle), 0)
        let memory = try XCTUnwrap(MemoryStats.current())
        XCTAssertGreaterThan(memory.used, 0)
        XCTAssertLessThanOrEqual(memory.usedFraction, 1)
        XCTAssertNotNil(DiskSpace.of())
        let processes = ProcessSample.all()
        XCTAssertTrue(processes.contains { $0.pid == getpid() }, "this test process is listed")
        _ = InterfaceCounters.current()
    }
    #endif
}
