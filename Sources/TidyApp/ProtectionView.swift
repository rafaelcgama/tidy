import SwiftUI
import TidyCore

/// What could start on its own or watch you: suspicious launch jobs and browser settings locked by a policy,
/// plus shortcuts to the System Settings pages that list who may use the camera, microphone and screen.
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
                        Text("Checked \(model.items.count) startup items at \(checked.formatted(date: .omitted, time: .shortened)).")
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
                ProgressView("Checking startup items…")
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
                    Section("Camera, microphone and screen") {
                        Text("System Settings lists the apps allowed to use your camera, microphone and screen, see what you type (Input Monitoring) or control your Mac (Accessibility). Turn off any you don't recognize.")
                            .foregroundStyle(.secondary)
                        HStack {
                            ForEach(Self.privacyPages) { page in
                                Button(page.title) { model.open(page.url) }
                            }
                        }
                        .padding(.vertical, 4)
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

    /// A System Settings page under Privacy & Security. macOS lists there who may use what; Tidy would need
    /// Full Disk Access to read that itself, and it goes without.
    private struct SettingsPage: Identifiable {
        let title: String
        let anchor: String
        var id: String { anchor }
        var url: URL { URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")! }
    }

    private static let privacyPages = [
        SettingsPage(title: "Camera", anchor: "Privacy_Camera"),
        SettingsPage(title: "Microphone", anchor: "Privacy_Microphone"),
        SettingsPage(title: "Screen Recording", anchor: "Privacy_ScreenCapture"),
        SettingsPage(title: "Input Monitoring", anchor: "Privacy_ListenEvent"),
        SettingsPage(title: "Accessibility", anchor: "Privacy_Accessibility"),
    ]

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
