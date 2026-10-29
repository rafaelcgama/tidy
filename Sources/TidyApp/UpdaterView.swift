import AppKit
import SwiftUI
import TidyCore

struct UpdaterView: View {
    @ObservedObject var model: UpdaterModel
    @ObservedObject var tidy = TidyUpdateModel.shared

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
            TidyUpdateRow(model: tidy)
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
        let count = model.updates.count + model.casks.count + (tidy.available == nil ? 0 : 1)
        return count == 0 ? "Everything is up to date" : "\(count) updates available"
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }
}

/// Tidy's own version, and the button that updates it, laid out like the app rows below it.
private struct TidyUpdateRow: View {
    @ObservedObject var model: TidyUpdateModel

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading) {
                Text("Tidy")
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch model.phase {
            case .checking:
                ProgressView()
                    .controlSize(.small)
            case .downloading, .installing:
                ProgressView()
                    .controlSize(.small)
                Text(model.phase == .downloading ? "Downloading…" : "Installing…")
                    .foregroundStyle(.secondary)
            case .idle:
                if model.available != nil {
                    Button("What's New") { model.openReleasePage() }
                    Button("Update Tidy") { model.install() }
                        .disabled(!model.canInstall)
                        .help(model.canInstall ? "Downloads the new Tidy, replaces this one and opens it again." : "Only the Tidy installed in Applications can update itself.")
                } else if model.hasChecked {
                    Text("Up to date")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .alert("Something went wrong", isPresented: errorShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// The installed app's icon; a copy run from Xcode has none of its own.
    @ViewBuilder
    private var icon: some View {
        if model.canInstall {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 28, height: 28)
        } else {
            Image(systemName: "sparkles")
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor))
        }
    }

    private var detail: String {
        if model.phase == .installing { return "Tidy will reopen when it's done." }
        let installed = model.installedVersion ?? "in development"
        if let release = model.available { return "\(installed) → \(release.version)" }
        return model.installedVersion.map { "Version \($0)" } ?? "Version in development"
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }
}
