import SwiftUI
import TidyCore

enum Module: String, CaseIterable, Identifiable {
    case smartCare = "Smart Care"
    case systemJunk = "System Junk"
    case clutter = "Clutter"
    case developer = "Developer"
    case cloud = "Cloud"
    case uninstaller = "Uninstaller"
    case updater = "Updater"
    case protection = "Protection"
    case malware = "Malware Scan"
    case privacy = "Privacy"
    case shredder = "Shredder"
    case optimization = "Optimization"
    case performance = "Performance"
    case spaceMap = "Space Map"
    case quarantine = "Quarantine"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .smartCare: return "sparkles"
        case .systemJunk: return "trash"
        case .clutter: return "doc.on.doc"
        case .developer: return "hammer"
        case .cloud: return "icloud"
        case .uninstaller: return "xmark.app"
        case .updater: return "arrow.down.app"
        case .protection: return "checkmark.shield"
        case .malware: return "ladybug"
        case .privacy: return "hand.raised"
        case .shredder: return "scissors"
        case .optimization: return "bolt"
        case .performance: return "speedometer"
        case .spaceMap: return "chart.pie"
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
    @StateObject private var systemJunk = ScanCleanModel { _ in
        let scanner = SystemJunkScanner(locations: SystemJunkScanner.defaultLocations() + SystemJunkScanner.systemLocations)
        return (scanner, scanner.safePaths)
    }
    @StateObject private var developer = ScanCleanModel(roots: [ContentView.defaultProjectsFolder]) { roots in
        let scanner = DeveloperJunkScanner(projectRoots: roots)
        return (scanner, scanner.safePaths)
    }
    @StateObject private var privacy = ScanCleanModel(preflight: BrowserCheck.browsersToQuit) { _ in
        let scanner = PrivacyScanner()
        return (scanner, scanner.safePaths)
    }
    @StateObject private var uninstaller = UninstallerModel()
    @StateObject private var spaceMap = SpaceMapModel()
    @StateObject private var clutter = ClutterModel()
    @StateObject private var protection = ProtectionModel()
    @StateObject private var optimization = OptimizationModel()
    @StateObject private var malware = MalwareModel()
    @StateObject private var shredder = ShredderModel()
    @StateObject private var cloud = CloudModel()
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
                                          blurb: "Find caches, logs, Xcode build files and other junk.",
                                          note: "Caches an app wrote to in the last 30 days aren't selected: they keep it fast, and removing them only means the app rebuilds them."))
            case .some(.developer):
                ScanCleanView(model: developer,
                              copy: .init(title: "Developer",
                                          symbol: "hammer.circle",
                                          blurb: "Find package caches (Homebrew, npm, pip, Gradle…) and build output in your projects (node_modules, target, .build).",
                                          choosesFolders: true,
                                          note: "Caches a tool used in the last 30 days aren't selected, so its next install doesn't download everything again."))
            case .some(.clutter):
                ClutterView(model: clutter)
            case .some(.cloud):
                CloudView(model: cloud)
            case .some(.uninstaller):
                UninstallerView(model: uninstaller)
            case .some(.updater):
                UpdaterView(model: updater)
            case .some(.protection):
                ProtectionView(model: protection)
            case .some(.malware):
                MalwareView(model: malware, reminders: reminders)
            case .some(.privacy):
                ScanCleanView(model: privacy,
                              copy: .init(title: "Privacy",
                                          symbol: "hand.raised.circle",
                                          blurb: "Find browsing history, cookies, autofill data and saved tabs in Safari, Chrome, Firefox and other browsers, plus your recent items.",
                                          note: "Passwords and bookmarks are never touched. Safari's data needs Full Disk Access. Firefox keeps history in the same file as bookmarks, so clear history in Firefox itself.",
                                          emptyMessage: "No browsing data found."))
            case .some(.shredder):
                ShredderView(model: shredder)
            case .some(.optimization):
                OptimizationView(model: optimization, monitor: monitor)
            case .some(.performance):
                PerformanceView(monitor: monitor, selection: $navigation.module)
            case .some(.spaceMap):
                SpaceMapView(model: spaceMap)
            case .some(.quarantine):
                QuarantineView(model: quarantine)
            case .none:
                Text("Pick a module")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    /// ~/Projects when it exists, otherwise the home folder.
    static var defaultProjectsFolder: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projects = home.appendingPathComponent("Projects")
        return FileManager.default.fileExists(atPath: projects.path) ? projects : home
    }
}
