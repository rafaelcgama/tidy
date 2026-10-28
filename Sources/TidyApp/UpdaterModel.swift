import AppKit
import Combine
import TidyCore

@MainActor
final class UpdaterModel: ObservableObject {
    @Published private(set) var updates: [AvailableUpdate] = []
    @Published private(set) var casks: [OutdatedCask] = []
    @Published private(set) var appStoreApps: [InstalledApp] = []
    @Published private(set) var isChecking = false
    @Published private(set) var hasChecked = false
    @Published private(set) var upgrading: Set<String> = []
    @Published var errorMessage: String?

    let hasHomebrew = Homebrew.executable != nil

    func check() {
        isChecking = true
        Task {
            let apps = await Task.detached { () -> [InstalledApp] in
                AppInventory.apps(in: AppInventory.defaultFolders())
            }.value
            updates = await SparkleUpdateChecker().check(apps, osVersion: SparkleUpdateChecker.currentOSVersion)
            if hasHomebrew {
                casks = (try? await Homebrew.outdatedCasks()) ?? []
            }
            appStoreApps = apps.filter(\.isFromAppStore)
            isChecking = false
            hasChecked = true
        }
    }

    func upgrade(_ cask: OutdatedCask) {
        upgrading.insert(cask.token)
        Task {
            do {
                _ = try await Homebrew.run(["upgrade", "--cask", cask.token])
                casks.removeAll { $0 == cask }
            } catch {
                errorMessage = "Couldn't update \(cask.token): \(error.localizedDescription)"
            }
            upgrading.remove(cask.token)
        }
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func openAppStoreUpdates() {
        if let url = URL(string: "macappstore://showUpdatesPage") {
            NSWorkspace.shared.open(url)
        }
    }
}
