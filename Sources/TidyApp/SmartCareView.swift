import AppKit
import SwiftUI
import TidyCore

/// One scan across cleanup and protection, with a single report before anything changes.
struct SmartCareView: View {
    @ObservedObject var model: SmartCareModel
    @ObservedObject var reminders: ReminderModel
    @Binding var selection: Module?
    @ObservedObject var tidy = TidyUpdateModel.shared
    @Environment(\.openWindow) private var openWindow
    @State private var reviewing: Review?

    /// What the confirmation lists before anything moves, and the report it came from.
    private struct Review {
        let items: [ScanItem]
        let report: SmartCareReport
    }

    var body: some View {
        content
            .navigationTitle("Smart Care")
            .sheet(isPresented: reviewShown) {
                if let review = reviewing {
                    ReviewSheet(title: "Clean this junk?",
                                actionTitle: "Move to Quarantine",
                                items: review.items,
                                retentionDays: model.store.retentionDays) {
                        reviewing = nil
                        model.clean(review.items, from: review.report)
                    } onCancel: {
                        reviewing = nil
                    }
                }
            }
            .alert("Something went wrong", isPresented: errorShown) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
    }

    private var reviewShown: Binding<Bool> {
        Binding(get: { reviewing != nil }, set: { if !$0 { reviewing = nil } })
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            VStack(spacing: 16) {
                Image(systemName: "sparkles")
                    .font(.system(size: 64))
                    .foregroundColor(.accentColor)
                Text("One scan for junk, login items and browser settings.")
                    .font(.title3)
                Text("You'll see everything it finds before anything changes.")
                    .foregroundStyle(.secondary)
                Button("Scan") { model.run() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                // A due reminder below already says how long it has been.
                if !reminders.due.contains(where: { $0.scan == .smartCare }) {
                    Text("Last scan: \(reminders.lastScanText(.smartCare))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Found by the check when Tidy starts; nothing installs until you choose to.
                if let release = tidy.available {
                    HStack {
                        Image(systemName: "arrow.down.circle")
                        Text("Tidy \(release.version) is available.")
                        Button("Update Tidy…") { openWindow(id: TidyUpdateWindow.id) }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
                }
                ForEach(reminders.due) { due in
                    HStack {
                        Image(systemName: "calendar.badge.clock")
                        Text(due.text)
                        if due.scan == .malware {
                            Button("Open Protection") { selection = .protection }
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .running(let step):
            VStack(spacing: 12) {
                ProgressView()
                Text(step)
                    .foregroundStyle(.secondary)
                Button("Stop") { model.cancel() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .report(let report):
            reportView(report)
        case .choosing(let report):
            listView(report)
        case .cleaning:
            ProgressView("Moving junk to quarantine…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done(let result):
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 56))
                    .foregroundColor(.green)
                Text("Moved \(ByteFormat.string(result.freedBytes)) of junk to quarantine")
                    .font(.title2.bold())
                Text("The disk space is freed when quarantine is emptied after \(model.store.retentionDays) days.")
                    .foregroundStyle(.secondary)
                if !result.skipped.isEmpty {
                    Text("\(result.skipped.count) items were skipped because they were in use, protected or already gone.")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    if let batch = result.batch {
                        Button("Undo") { model.undo(batch) }
                    }
                    Button("Done") { model.reset() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Where macOS lists the apps Tidy may control, Mail and Finder among them.
    private static let automationSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    @ViewBuilder
    private var mailJunkText: some View {
        switch model.mailJunk {
        case .ready:
            Text("Marks the unread messages in Mail's Junk as read, in all your accounts.")
                .foregroundStyle(.secondary)
        case .marking:
            Text("Mail is marking your junk as read…")
                .foregroundStyle(.secondary)
        case .finished(.marked(0)):
            Text("Mail's Junk has no unread messages.")
        case .finished(.marked(1)):
            Text("Marked 1 junk message as read.")
        case .finished(.marked(let count)):
            Text("Marked \(count) junk messages as read.")
        case .finished(.notAllowed):
            Text("macOS doesn't let Tidy control Mail. Turn on Mail under Tidy in Privacy & Security › Automation.")
        case .finished(.failed(let reason)):
            Text("Mail didn't mark the junk as read. \(reason)")
        }
    }

    /// "3 more leftovers of removed apps (12 MB) aren't selected…"
    private func unsureText(_ items: [ScanItem], more: Bool) -> String {
        let what = items.count == 1 ? "leftover of removed apps isn't" : "leftovers of removed apps aren't"
        return "\(items.count) \(more ? "more " : "")\(what) selected (\(ByteFormat.string(items.totalSize))), because Tidy can't be sure. Review & Clean… lists them to tick."
    }

    private func reportView(_ report: SmartCareReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card(title: "Cleanup", symbol: "trash.circle.fill", tint: .blue) {
                    let selected = model.selectedCleanup
                    // What removed apps left that Tidy can't be sure about isn't selected, so it's named here.
                    let unsure = model.cleanup.filter { !$0.isSelected && $0.category == LeftoverFinder.orphanCategory }
                    if model.cleanup.isEmpty {
                        Text("No junk to clean.")
                            .foregroundStyle(.secondary)
                    } else if selected.isEmpty && unsure.isEmpty {
                        Text("Nothing is selected for you. Review & Clean… lists what was found, such as caches in use, to tick yourself.")
                            .foregroundStyle(.secondary)
                    }
                    if !selected.isEmpty {
                        Text("\(ByteFormat.string(selected.totalSize)) of caches, logs, leftovers of removed apps and other junk in \(selected.count) items.")
                    }
                    if !unsure.isEmpty {
                        Text(unsureText(unsure, more: !selected.isEmpty))
                            .foregroundStyle(.secondary)
                    }
                    if !model.cleanup.isEmpty {
                        Button("Review & Clean…") { model.choose(report) }
                            .keyboardShortcut(.defaultAction)
                    }
                }

                // macOS keeps what's in the Trash from apps without Full Disk Access, so Finder shows and empties it.
                Card(title: "Trash", symbol: "trash.fill", tint: .orange) {
                    Text("Finder shows what's in the Trash and empties it.")
                        .foregroundStyle(.secondary)
                    Button("Open Trash") { FinderTrash.show() }
                }

                // Mail marks the junk itself, in each account and on each account's server.
                Card(title: "Junk Mail", symbol: "xmark.bin.fill", tint: .brown) {
                    mailJunkText
                    HStack {
                        Button("Mark Junk as Read") { model.markMailJunkRead() }
                            .disabled(model.mailJunk == .marking)
                        if model.mailJunk == .marking {
                            ProgressView()
                                .controlSize(.small)
                        }
                        if model.mailJunk == .finished(.notAllowed) {
                            Button("Open Privacy & Security") { NSWorkspace.shared.open(Self.automationSettings) }
                        }
                    }
                }

                Card(title: "Protection", symbol: "checkmark.shield.fill",
                     tint: report.findings.contains { $0.severity == .danger } ? .red : .green) {
                    if report.findings.isEmpty {
                        Text("Nothing suspicious in login items, agents or browser settings.")
                            .foregroundStyle(.secondary)
                    } else {
                        let serious = report.findings.filter { $0.severity == .danger }.count
                        Text("\(report.findings.count) things worth a look, \(serious) of them serious.")
                        Button("Open Protection") { selection = .protection }
                    }
                }

                Card(title: "Apps", symbol: "xmark.app.fill", tint: .purple) {
                    Text("Which apps to remove needs your judgment, so Smart Care leaves that to the Uninstaller.")
                        .foregroundStyle(.secondary)
                    Button("Open Uninstaller") { selection = .uninstaller }
                }

                HStack {
                    Spacer()
                    Button("Scan Again") { model.run() }
                }
            }
            .padding(20)
        }
    }

    /// Everything the scan found, by kind, to tick item by item before cleaning.
    private func listView(_ report: SmartCareReport) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.closeList(report) } label: {
                    Label("Report", systemImage: "chevron.left")
                }
                Spacer()
                Text("\(model.cleanup.count) items, \(ByteFormat.string(model.cleanup.totalSize)) in all")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            List {
                ForEach(model.cleanupGroups) { group in
                    ItemGroupRow(group: group,
                                 toggleItem: { model.toggle($0) },
                                 setCategory: { model.setCategory($0, selected: $1) })
                }
            }
            Divider()
            SelectionBar(allSelected: model.allCleanupSelected,
                         summary: model.selectedCleanup.selectionSummary(verb: "clean"),
                         selectAll: { model.selectAll($0) }) {
                Button("Clean Selected…") { reviewing = Review(items: model.selectedCleanup, report: report) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectedCleanup.isEmpty)
                Button("Clean All…") { reviewing = Review(items: model.cleanup, report: report) }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            Text("Caches used in the last 30 days, leftovers of removed apps Tidy can't be sure about and system junk aren't selected for you. What you clean waits in Quarantine for \(model.store.retentionDays) days, so you can put it back. Right-click an item to reveal it in Finder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }
}

private struct Card<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundColor(tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                content
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }
}

extension FinderTrash {
    /// Finder's Trash, as the Dock opens it. If macOS doesn't let Tidy ask Finder, your Trash folder,
    /// which holds only what you deleted on this Mac.
    @MainActor static func show() {
        Task {
            if await Task.detached(operation: { FinderTrash().open() }).value { return }
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
        }
    }
}
