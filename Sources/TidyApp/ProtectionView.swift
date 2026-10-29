import SwiftUI
import TidyCore

/// What could start on its own or watch you: suspicious launch jobs, browser settings locked by a policy,
/// browser extensions, and the apps allowed to use the camera, microphone, screen and files.
struct ProtectionView: View {
    @ObservedObject var model: ProtectionModel
    @State private var pendingRemoval: Finding?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary)
                        .font(.headline)
                    if let checked = model.lastChecked {
                        Text("Checked \(model.items.count) startup items and \(model.extensions.count) browser extensions at \(checked.formatted(date: .omitted, time: .shortened)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Scan Again") { model.refresh() }
                    .disabled(model.isLoading)
            }
            .padding(12)
            Divider()
            if model.isLoading && !model.hasLoaded {
                ProgressView("Checking startup items, browser extensions and privacy settings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section("Startup items and browser settings") {
                        if model.findings.isEmpty {
                            Label("Nothing suspicious found. Tidy checks how things start on your Mac, who signed the programs they run, and whether your browser settings are locked. It doesn't replace macOS's built-in XProtect.",
                                  systemImage: "checkmark.shield")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                        }
                        ForEach(model.findings) { finding in
                            FindingRow(finding: finding,
                                       canRemove: model.canRemove(finding.url),
                                       reveal: { model.reveal(finding.url) },
                                       remove: { pendingRemoval = finding })
                        }
                    }
                    Section("Browser extensions") {
                        if model.extensions.isEmpty {
                            Text("No browser extensions found.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.extensions) { item in
                            ExtensionRow(item: item, reveal: { model.reveal(item.url) })
                        }
                        Text("Turn an extension off or remove it in its browser's settings. Safari's extensions come with apps, so removing the app with the Uninstaller removes them too.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section("Camera, microphone, screen and files") {
                        PermissionRows(report: model.permissions, open: { model.open($0) })
                    }
                }
            }
            if let notice = model.notice {
                Divider()
                HStack {
                    Text(notice)
                    Spacer()
                    Button("Undo") { model.undoLast() }
                }
                .padding(12)
            }
        }
        .navigationTitle("Protection")
        .onAppear {
            if !model.hasLoaded { model.refresh() }
        }
        .confirmationDialog("Stop this from starting at login?",
                            isPresented: removalShown,
                            presenting: pendingRemoval) { finding in
            Button("Move to Quarantine", role: .destructive) {
                model.remove(finding.url, name: finding.title)
            }
        } message: { finding in
            Text("\(finding.url.path) will be moved to quarantine. You can undo this for \(model.store.retentionDays) days.")
        }
        .alert("Something went wrong", isPresented: errorShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var summary: String {
        if !model.hasLoaded { return "Checking…" }
        if model.findings.isEmpty { return "Nothing suspicious" }
        return "\(model.findings.count) findings, \(model.dangerCount) serious"
    }

    private var removalShown: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }
}

private struct FindingRow: View {
    let finding: Finding
    let canRemove: Bool
    let reveal: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(finding.title)
                    .font(.headline)
                ForEach(finding.reasons, id: \.self) { reason in
                    Text("• \(reason)")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(finding.url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack {
                    Button("Reveal in Finder", action: reveal)
                    if canRemove {
                        Button("Move to Quarantine…", action: remove)
                    } else {
                        Text("Tidy doesn't remove this one itself.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
    }

    private var symbol: String {
        switch finding.severity {
        case .danger: return "xmark.shield.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .notice: return "info.circle.fill"
        }
    }

    private var color: Color {
        switch finding.severity {
        case .danger: return .red
        case .warning: return .orange
        case .notice: return .blue
        }
    }
}

private struct ExtensionRow: View {
    let item: BrowserExtension
    let reveal: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .font(.title2)
                .foregroundColor(item.readsAllSites ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.headline)
                Text([item.browser, item.version.map { "version \($0)" }, item.app.map { "comes with \($0)" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if item.readsAllSites {
                    Text("Can read and change everything on every website you visit.")
                        .foregroundColor(.orange)
                }
            }
            Spacer()
            Button("Reveal in Finder", action: reveal)
        }
        .padding(.vertical, 4)
    }
}

/// The apps allowed each kind of access, with a way to the System Settings page that turns it off.
private struct PermissionRows: View {
    let report: PrivacyPermissions.Report?
    let open: (URL) -> Void

    var body: some View {
        if let report {
            if !report.isComplete {
                HStack {
                    Text(report.grants.isEmpty
                         ? "Tidy needs Full Disk Access to see which apps can use your camera, microphone and screen."
                         : "Some of these settings couldn't be read. With Full Disk Access, Tidy sees them all.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Full Disk Access Settings") { open(PrivacyPermissions.fullDiskAccessSettings) }
                }
                .padding(.vertical, 4)
            } else if report.grants.isEmpty {
                Text("No app can use your camera, microphone or screen, see what you type, control your Mac or read every file.")
                    .foregroundStyle(.secondary)
            }
            ForEach(PrivacyPermissions.kinds, id: \.service) { kind in
                let names = report.grants.filter { $0.kind == kind }.map(\.name)
                if !names.isEmpty {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(kind.title)
                                .font(.headline)
                            Text(names.joined(separator: ", "))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Change in System Settings") { open(kind.settingsURL) }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}
