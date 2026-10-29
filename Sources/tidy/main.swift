import Foundation
import TidyCore

let usage = """
usage: tidy scan                 list system junk and its size
       tidy clean --dry-run      show what clean would move to quarantine
       tidy clean                move the preselected junk to quarantine (asks first)
       tidy updates              list apps and Homebrew casks with newer versions
       tidy stats                CPU, memory, disk, network and the busiest processes
       tidy malware [path…]      check for malware (default: Downloads, apps, login items, shared and temporary folders)
       tidy malware --quarantine [path…]
                                 the same, then move what it finds to quarantine (asks first)
       tidy quarantine           list what is in quarantine
       tidy restore <batch-id>   put a quarantined batch back where it came from
"""

let scanner = CombinedScanner.systemJunk()
let store = QuarantineStore(root: QuarantineStore.defaultRoot)
/// What the app's admin helper moved. Readable here; only the app can put it back, through the helper.
let systemStore = QuarantineStore(root: QuarantineStore.systemRoot)

func printGroups(_ items: [ScanItem]) {
    for group in items.groupedByCategory() {
        print("\(group.category)  \(ByteFormat.string(group.totalSize))  (\(group.items.count) items)")
        for item in group.items {
            let mark = item.isSelected ? "*" : " "
            print("  \(mark) \(ByteFormat.string(item.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(item.url.path)"
                  + (item.label.map { "  (\($0))" } ?? ""))
        }
    }
}

func run(_ args: [String]) async throws -> Int32 {
    let expired = try store.purgeExpired()
    if !expired.isEmpty {
        let size = expired.reduce(0) { $0 + $1.totalSize }
        print("Permanently removed \(expired.count) quarantine batches older than \(store.retentionDays) days (\(ByteFormat.string(size))).")
    }

    switch args.first {
    case "scan":
        let items = try await scanner.scan { _ in }
        printGroups(items)
        print("\nTotal: \(ByteFormat.string(items.totalSize)). Items marked * are selected by `tidy clean`.")
        return 0

    case "clean":
        let dryRun = args.contains("--dry-run")
        let cleaner = QuarantineCleaner(store: store, safePaths: scanner.safePaths)
        let items = try await scanner.scan { _ in }
        let plan = try await cleaner.clean(items, dryRun: true)
        guard !plan.removed.isEmpty else {
            print("Nothing to clean.")
            return 0
        }
        printGroups(plan.removed)
        print("\n\(plan.removed.count) items, \(ByteFormat.string(plan.freedBytes)).")
        if dryRun {
            print("Dry run: nothing was changed.")
            return 0
        }
        print("Move these to quarantine? They can be restored for \(store.retentionDays) days. Type yes to continue: ", terminator: "")
        guard readLine()?.lowercased() == "yes" else {
            print("Cancelled. Nothing was changed.")
            return 1
        }
        let result = try await cleaner.clean(plan.removed, dryRun: false)
        print("Moved \(result.removed.count) items (\(ByteFormat.string(result.freedBytes))) to quarantine.")
        if let batch = result.batch {
            print("Undo with: tidy restore \(batch.id)")
        }
        for skipped in result.skipped {
            print("  skipped \(skipped.item.url.path): \(skipped.reason)")
        }
        return 0

    case "updates":
        var lines: [String] = []
        #if os(macOS)
        let apps = AppInventory.apps(in: AppInventory.defaultFolders())
        let updates = await SparkleUpdateChecker().check(apps, osVersion: SparkleUpdateChecker.currentOSVersion)
        for update in updates {
            lines.append("\(update.app.name)  \(update.currentVersion) → \(update.item.displayVersion)")
        }
        #endif
        if Homebrew.executable != nil {
            for cask in try await Homebrew.outdatedCasks() {
                lines.append("\(cask.token) (Homebrew)  \(cask.installedVersion) → \(cask.currentVersion)  brew upgrade --cask \(cask.token)")
            }
        }
        print(lines.isEmpty ? "Everything is up to date." : lines.joined(separator: "\n"))
        print("Nothing was installed.")
        return 0

    case "stats":
        #if os(macOS)
        let ticks = CPUTicks.current()
        let interfaces = InterfaceCounters.current()
        let processes = ProcessSample.all()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        if let ticks, let now = CPUTicks.current() {
            print("CPU      \(Int((now.usage(since: ticks) * 100).rounded()))%")
        }
        if let memory = MemoryStats.current() {
            let used = ByteFormat.string(Int64(clamping: memory.used)), total = ByteFormat.string(Int64(clamping: memory.total))
            print("Memory   \(used) of \(total) used, pressure \(memory.pressure)")
        }
        if let disk = DiskSpace.of() {
            print("Disk     \(ByteFormat.string(disk.available)) free of \(ByteFormat.string(disk.total))")
        }
        let rate = NetworkRate(from: interfaces, to: InterfaceCounters.current(), seconds: 1)
        print("Network  down \(ByteFormat.string(Int64(rate.receivedPerSecond)))/s, up \(ByteFormat.string(Int64(rate.sentPerSecond)))/s")
        print("\nBusiest processes (CPU % of one core):")
        for load in ProcessLoad.compare(processes, ProcessSample.all(), seconds: 1).prefix(10) {
            let memory = ByteFormat.string(Int64(clamping: load.memory)).padding(toLength: 10, withPad: " ", startingAt: 0)
            print("  \(String(format: "%6.1f", load.cpuPercent))  \(memory) \(load.name)")
        }
        return 0
        #else
        print("tidy stats needs macOS.")
        return 1
        #endif

    case "malware":
        let moving = args.contains("--quarantine")
        let paths = args.dropFirst().filter { $0 != "--quarantine" }.map { URL(fileURLWithPath: $0) }
        let signatures = MalwareSignatures.load()
        for source in signatures.sources {
            let count = "\(source.count) \(source.kind == .hashes ? "hashes" : "rules")"
            print("\(source.name): \(source.problem.map { "not loaded, \($0)" } ?? count)")
        }
        let scanner = MalwareScanner(targets: paths.isEmpty ? .quick() : .init(folders: paths), signatures: signatures)
        let report = try await scanner.scan()
        print("\nChecked \(report.scannedFiles) files (\(ByteFormat.string(report.scannedBytes))).")
        var notChecked: [String] = []
        if report.unreadable > 0 { notChecked.append("\(report.unreadable) unreadable") }
        if report.tooLarge > 0 { notChecked.append("\(report.tooLarge) larger than \(ByteFormat.string(scanner.maxFileSize))") }
        if report.cloudOnly > 0 { notChecked.append("\(report.cloudOnly) only in iCloud") }
        if report.timedOut > 0 { notChecked.append("\(report.timedOut) too slow to scan") }
        if !notChecked.isEmpty { print("Not checked: " + notChecked.joined(separator: "; ") + ".") }
        guard !report.threats.isEmpty else {
            print("No malware found.")
            return 0
        }
        for threat in report.threats {
            print("\n\(threat.name)  \(ByteFormat.string(threat.size))  \(threat.url.path)")
            for detection in threat.detections {
                print("    \(detection.file.path): \(detection.summary)")
            }
        }
        guard moving else {
            print("\nNothing was changed. Move these to quarantine with tidy malware --quarantine, or from Tidy's Malware Scan screen.")
            return 0
        }
        print("\nMove these \(report.threats.count) items to quarantine? They can be restored for \(store.retentionDays) days. Type yes to continue: ", terminator: "")
        guard readLine()?.lowercased() == "yes" else {
            print("Cancelled. Nothing was changed.")
            return 1
        }
        // The threats themselves are the allowlist, so nothing else can move.
        let cleaner = QuarantineCleaner(store: store, safePaths: SafePaths(allowedRoots: report.threats.map(\.url)))
        let result = try await cleaner.clean(report.threats.map(\.scanItem), dryRun: false)
        print("Moved \(result.removed.count) items to quarantine.")
        if let batch = result.batch {
            print("Undo with: tidy restore \(batch.id)")
        }
        for skipped in result.skipped {
            print("  not moved \(skipped.item.url.path): \(skipped.reason). Items that belong to root need Tidy's admin helper: use the Malware Scan screen.")
        }
        return 0

    case "quarantine":
        let batches = store.batches()
        let systemBatches = systemStore.batches()
        if batches.isEmpty && systemBatches.isEmpty { print("Quarantine is empty.") }
        for batch in batches {
            print("\(batch.id)  \(batch.date)  \(batch.entries.count) items  \(ByteFormat.string(batch.totalSize))")
        }
        for batch in systemBatches {
            print("\(batch.id)  \(batch.date)  \(batch.entries.count) items  \(ByteFormat.string(batch.totalSize))  (moved by the admin helper)")
        }
        return 0

    case "restore" where args.count == 2:
        let id = args[1]
        guard store.hasBatch(id) || systemStore.hasBatch(id) else {
            throw QuarantineError.invalidBatchID(id)
        }
        if store.hasBatch(id) {
            let result = try store.restore(batchID: id)
            print("Restored \(result.restored.count) items.")
            for skipped in result.skipped {
                print("  not restored \(skipped.entry.originalPath): \(skipped.reason)")
            }
        }
        if systemStore.hasBatch(id) {
            print("Items the admin helper moved need administrator rights to put back: use Put Back in Tidy's Quarantine screen.")
        }
        return 0

    default:
        print(usage)
        return 64
    }
}

do {
    exit(try await run(Array(CommandLine.arguments.dropFirst())))
} catch {
    FileHandle.standardError.write(Data("tidy: \(error.localizedDescription)\n".utf8))
    exit(1)
}
