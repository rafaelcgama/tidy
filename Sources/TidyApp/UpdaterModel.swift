import AppKit
import Combine
import TidyCore

@MainActor
final class UpdaterModel: ObservableObject {
    @Published private(set) var updates: [AvailableUpdate] = []
    @Published private(set) var casks: [OutdatedCask] = []
    @Published private(set) var isChecking = false
    @Published private(set) var hasChecked = false
    @Published private(set) var upgrading: Set<String> = []
    @Published var errorMessage: String?

    let hasHomebrew = Homebrew.executable != nil

    /// Checks Tidy itself too.
    func check() {
        guard !isChecking else { return }
        isChecking = true
        TidyUpdateModel.shared.check()
        Task {
            let apps = await Task.detached { () -> [InstalledApp] in
                AppInventory.apps(in: AppInventory.defaultFolders())
            }.value
            updates = await SparkleUpdateChecker().check(apps, osVersion: SparkleUpdateChecker.currentOSVersion)
            if hasHomebrew {
                casks = (try? await Homebrew.outdatedCasks()) ?? []
            }
            isChecking = false
            hasChecked = true
        }
    }

    func upgrade(_ cask: OutdatedCask) {
        upgrading.insert(cask.token)
        Task {
            do {
                try await Homebrew.upgrade(cask.token)
            } catch {
                errorMessage = "Couldn't update \(cask.token): \(error.localizedDescription)"
            }
            // Ask Homebrew again rather than assume, so the list shows what really happened.
            casks = (try? await Homebrew.outdatedCasks()) ?? casks
            if errorMessage == nil, casks.contains(where: { $0.token == cask.token }) {
                errorMessage = "Homebrew didn't update \(cask.token). Run `brew upgrade --cask --greedy \(cask.token)` in Terminal to see why."
            }
            upgrading.remove(cask.token)
        }
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

}
