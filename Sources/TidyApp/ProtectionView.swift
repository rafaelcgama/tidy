import AppKit
import SwiftUI
import TidyCore

/// Everything that could harm your Mac or watch you: a malware scan against Apple's own list, suspicious launch
/// jobs and browser settings locked by a policy, and shortcuts to the System Settings pages that list who may use
/// the camera, microphone and screen.
struct ProtectionView: View {
    @ObservedObject var model: ProtectionModel
    @ObservedObject var malware: MalwareModel
    @ObservedObject var reminders: ReminderModel
    @State private var pendingRemoval: Finding?
    /// The threats the confirmation lists before anything moves.
    @State private var reviewing: [ScanItem]?
    @State private var browsers: [Browser] = []

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    MalwareSection(model: malware, reminders: reminders)
                } header: {
                    SectionTitle(title: "Malware",
                                 detail: "Checks your files against Apple's own malware list, the one macOS uses, which Apple keeps up to date.")
                }
                Section("Startup items and browser settings") {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary)
                                .font(.headline)
                            Text(startupDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if model.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button("Check Again") { model.refresh() }
                            .disabled(model.isLoading)
                    }
                    .padding(.vertical, 4)
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
                if !browsers.isEmpty {
                    Section {
                        ForEach(browsers) { browser in
                            OpenRow(title: browser.name, detail: browser.hint, button: "Open") {
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
                        Text("Lists Chrome, Firefox, Edge and Brave when they're on your Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // Under the list, as in Quarantine, while a scan's threats are listed.
            if malware.showsThreats {
                Divider()
                SelectionBar(allSelected: malware.allSelected,
                             summary: malware.selectedItems.selectionSummary(verb: "quarantine"),
                             selectAll: { malware.selectAll($0) }) {
                    Button("Quarantine Selected…") { reviewing = malware.selectedItems }
                        .keyboardShortcut(.defaultAction)
                        .disabled(malware.selectedItems.isEmpty)
                    Button("Quarantine All…") { reviewing = malware.threats.map(\.scanItem) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
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
            if malware.sources == nil { malware.loadSignatures() }
            browsers = Browser.installed()
        }
        .sheet(isPresented: reviewShown) {
            if let items = reviewing {
                ReviewSheet(title: "Move these threats to quarantine?",
                            actionTitle: "Move to Quarantine",
                            items: items,
                            retentionDays: malware.store.retentionDays) {
                    reviewing = nil
                    malware.clean(items)
                } onCancel: {
                    reviewing = nil
                }
            }
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
            Text(model.errorMessage ?? malware.errorMessage ?? "")
        }
    }

    private var summary: String {
        if !model.hasLoaded { return "Checking…" }
        if model.findings.isEmpty { return "Nothing suspicious" }
        return "\(model.findings.count) findings, \(model.dangerCount) serious"
    }

    private var startupDetail: String {
        let what = "Looks at how things start on your Mac, who signed the programs they run, and whether your browser settings are locked."
        guard let checked = model.lastChecked else { return what }
        return what + " Checked \(model.items.count) startup items at \(checked.formatted(date: .omitted, time: .shortened))."
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

    private var reviewShown: Binding<Bool> {
        Binding(get: { reviewing != nil }, set: { if !$0 { reviewing = nil } })
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { model.errorMessage != nil || malware.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil; malware.errorMessage = nil } })
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
