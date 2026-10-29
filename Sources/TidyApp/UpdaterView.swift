import AppKit
import SwiftUI
import TidyCore

struct UpdaterView: View {
    @ObservedObject var model: UpdaterModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(summary)
                    .font(.headline)
                Spacer()
                if model.isChecking {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Check for Updates") { model.check() }
                    .disabled(model.isChecking)
            }
            .padding(12)
            Divider()
            if !model.hasChecked {
                VStack(spacing: 14) {
                    Image(systemName: "arrow.down.app")
                        .font(.system(size: 56))
                        .foregroundColor(.accentColor)
                    Text("Check apps that update themselves (Sparkle) and Homebrew apps for newer versions.")
                        .font(.title3)
                        .multilineTextAlignment(.center)
                    Text("Checking contacts each app's update server. Nothing is installed without you.")
                        .foregroundStyle(.secondary)
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section("Apps") {
                        if model.updates.isEmpty {
                            Text("All apps that use Sparkle are up to date.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.updates) { update in
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: update.app.url.path))
                                    .resizable()
                                    .frame(width: 28, height: 28)
                                VStack(alignment: .leading) {
                                    Text(update.app.name)
                                    Text("\(update.currentVersion) → \(update.item.displayVersion)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let notes = update.item.releaseNotesURL {
                                    Button("Release Notes") { model.open(notes) }
                                }
                                Button("Open App to Update") { model.open(update.app.url) }
                                    .help("Opens the app. Its own updater (usually Check for Updates… in the app menu) installs the new version.")
                            }
                        }
                    }
                    if model.hasHomebrew {
                        Section("Homebrew") {
                            if model.casks.isEmpty {
                                Text("All Homebrew casks are up to date.")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(model.casks) { cask in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(cask.token)
                                        Text("\(cask.installedVersion) → \(cask.currentVersion)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if model.upgrading.contains(cask.token) {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Button("Update") { model.upgrade(cask) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Updater")
        // Back from updating an app in its own window, the list checks again by itself.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if model.hasChecked { model.check() }
        }
        .alert("Something went wrong", isPresented: errorShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var summary: String {
        guard model.hasChecked else { return "Updates" }
        let count = model.updates.count + model.casks.count
        return count == 0 ? "Everything is up to date" : count == 1 ? "1 update available" : "\(count) updates available"
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }
}
