import SwiftUI
import TidyCore

enum Module: String, CaseIterable, Identifiable {
    case smartCare = "Smart Care"
    case systemJunk = "System Junk"
    case uninstaller = "Uninstaller"
    case updater = "Updater"
    case protection = "Protection"
    case malware = "Malware Scan"
    case performance = "Performance"
    case quarantine = "Quarantine"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .smartCare: return "sparkles"
        case .systemJunk: return "trash"
        case .uninstaller: return "xmark.app"
        case .updater: return "arrow.down.app"
        case .protection: return "checkmark.shield"
        case .malware: return "ladybug"
        case .performance: return "speedometer"
        case .quarantine: return "arrow.uturn.backward.circle"
        }
    }
}

/// Which module the main window shows, so the menu bar can send you to one.
@MainActor
final class AppNavigation: ObservableObject {
    @Published var module: Module? = .smartCare
}

struct ContentView: View {
    /// Shared with the menu bar; only the Performance screen observes it.
    let monitor: SystemMonitor
    let reminders: ReminderModel
    @ObservedObject var navigation: AppNavigation
    @StateObject private var smartCare = SmartCareModel()
    @StateObject private var systemJunk = ScanCleanModel {
        let scanner = CombinedScanner.systemJunk()
        return (scanner, scanner.safePaths)
    }
    @StateObject private var uninstaller = UninstallerModel()
    @StateObject private var protection = ProtectionModel()
    @StateObject private var malware = MalwareModel()
    @StateObject private var updater = UpdaterModel()
    @StateObject private var quarantine = QuarantineModel()

    var body: some View {
        NavigationSplitView {
            List(Module.allCases, selection: $navigation.module) { module in
                Label(module.rawValue, systemImage: module.symbol)
                    .tag(module)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch navigation.module {
            case .some(.smartCare):
                SmartCareView(model: smartCare, reminders: reminders, selection: $navigation.module)
            case .some(.systemJunk):
                ScanCleanView(model: systemJunk,
                              copy: .init(title: "System Junk",
                                          symbol: "trash.circle",
                                          blurb: "Find what removed apps left behind, app and package caches (Homebrew, npm, pip…), logs, Xcode build files and simulators, old installers and other junk.",
                                          note: "Caches used in the last 30 days aren't selected: they keep apps and installs fast, and removing them only means they're rebuilt. "
                                              + "Old macOS installers, simulators Xcode can no longer run and installers in Downloads over a week old are selected. "
                                              + "Of what removed apps left, only what can't matter is selected, such as startup items that start nothing: check the rest yourself."))
            case .some(.uninstaller):
                UninstallerView(model: uninstaller)
            case .some(.updater):
                UpdaterView(model: updater)
            case .some(.protection):
                ProtectionView(model: protection)
            case .some(.malware):
                MalwareView(model: malware, reminders: reminders)
            case .some(.performance):
                PerformanceView(monitor: monitor, selection: $navigation.module)
            case .some(.quarantine):
                QuarantineView(model: quarantine)
            case .none:
                Text("Pick a module")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}
