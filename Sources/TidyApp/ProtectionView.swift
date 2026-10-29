import AppKit
import SwiftUI
import TidyCore

/// What could start on its own or watch you: suspicious launch jobs and browser settings locked by a policy,
/// plus shortcuts to the System Settings pages that list who may use the camera, microphone and screen.
struct ProtectionView: View {
    @ObservedObject var model: ProtectionModel
    @State private var pendingRemoval: Finding?
    @State private var browsers: [Browser] = []

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
                    Section {
                        ForEach(Self.privacyPages) { page in
                            OpenRow(title: page.title, detail: page.detail, button: "Open") {
                                Image(systemName: page.symbol)
                                    .foregroundColor(.white)
                                    .frame(width: 26, height: 26)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(page.tint))
                            } action: {
                                model.open(page.url)
                            }
                        }
                    } header: {
                        SectionTitle(title: "Apps that can watch you or control your Mac",
                                     detail: "Listed in System Settings. Turn off any you don't recognize.")
                    }
                    Section {
                        ForEach(browsers) { browser in
                            OpenRow(title: browser.name, detail: browser.hint,
                                    button: browser.page == nil ? "Open \(browser.name)" : "Open") {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: browser.app.path))
                                    .resizable()
                                    .frame(width: 26, height: 26)
                            } action: {
                                model.open(browser)
                            }
                        }
                    } header: {
                        SectionTitle(title: "Websites that can watch you",
                                     detail: "Listed in each browser. Remove any site you don't recognize.")
                    } footer: {
                        Text("Only browsers on your Mac are listed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
            browsers = Browser.installed()
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
        let detail: String
        let symbol: String
        let tint: Color
        let anchor: String
        var id: String { anchor }
        var url: URL { URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")! }
    }

    private static let privacyPages = [
        SettingsPage(title: "Camera", detail: "Apps that can turn on your camera",
                     symbol: "video.fill", tint: .green, anchor: "Privacy_Camera"),
        SettingsPage(title: "Microphone", detail: "Apps that can listen through your microphone",
                     symbol: "mic.fill", tint: .orange, anchor: "Privacy_Microphone"),
        SettingsPage(title: "Screen Recording", detail: "Apps that can see everything on your screen",
                     symbol: "rectangle.inset.filled.on.rectangle", tint: .purple, anchor: "Privacy_ScreenCapture"),
        SettingsPage(title: "Input Monitoring", detail: "Apps that can see what you type, passwords included",
                     symbol: "keyboard", tint: .gray, anchor: "Privacy_ListenEvent"),
        SettingsPage(title: "Accessibility", detail: "Apps that can control your Mac: click, type and read other apps' windows",
                     symbol: "accessibility", tint: .blue, anchor: "Privacy_Accessibility"),
    ]

    private var removalShown: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }
}

/// A section title with a line under it saying where the list lives and what to do with it.
private struct SectionTitle: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.callout)
                .fontWeight(.regular)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }
}

/// One thing to check: an icon, what it is, what it allows, and a button that opens where it's listed.
private struct OpenRow<Icon: View>: View {
    let title: String
    let detail: String
    let button: String
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            icon()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(button, action: action)
        }
        .padding(.vertical, 4)
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
