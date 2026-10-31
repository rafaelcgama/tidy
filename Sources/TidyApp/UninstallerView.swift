import AppKit
import SwiftUI
import TidyCore

struct UninstallerView: View {
    @ObservedObject var model: UninstallerModel
    /// What the confirmation lists before anything moves.
    @State private var reviewing: [ScanItem]?

    var body: some View {
        HSplitView {
            appList
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
            detail
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Uninstaller")
        // Read Applications again each time, so apps installed or removed while Tidy is open show up.
        .onAppear { model.loadApps() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.loadApps()
        }
        .sheet(isPresented: reviewShown) {
            if let items = reviewing {
                ReviewSheet(title: "Remove \(model.selection?.name ?? "this app")?",
                            actionTitle: "Move to Quarantine",
                            items: items,
                            retentionDays: model.store.retentionDays) {
                    reviewing = nil
                    model.remove(items)
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

    private var errorShown: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }

    private var reviewShown: Binding<Bool> {
        Binding(get: { reviewing != nil }, set: { if !$0 { reviewing = nil } })
    }

    private var appList: some View {
        VStack(spacing: 0) {
            TextField("Search apps", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .padding([.horizontal, .top], 8)
            Picker("Sort by", selection: $model.sort) {
                ForEach(UninstallerModel.Sort.allCases) { sort in
                    Text(sort.rawValue).tag(sort)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            List(selection: $model.selection) {
                Section("Applications") {
                    ForEach(model.filteredApps) { app in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                .resizable()
                                .frame(width: 20, height: 20)
                            VStack(alignment: .leading) {
                                Text(app.name)
                                // Unused apps stand out: never opened, or not in six months.
                                Text([app.version, model.usageText(app)].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundColor(model.isUnused(app) ? .orange : .secondary)
                            }
                        }
                        .tag(app)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.phase {
        case .empty:
            VStack(spacing: 10) {
                Image(systemName: "xmark.app")
                    .font(.system(size: 56))
                    .foregroundColor(.accentColor)
                Text("Pick an app to remove it and everything it put on your Mac.")
                Text("Sort by Last Opened to find apps you no longer use.")
                Text("Smart Care finds what apps you already deleted left behind.")
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .scanning:
            ProgressView("Looking for related files…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .results:
            results
        case .removing:
            ProgressView("Moving to quarantine…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done(let result):
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 56))
                    .foregroundColor(.green)
                Text("Moved \(result.removed.count) items (\(ByteFormat.string(result.freedBytes))) to quarantine")
                    .font(.title2.bold())
                if !result.skipped.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(result.skipped.count) items weren't moved:")
                            .font(.headline)
                        List(Array(result.skipped.enumerated()), id: \.offset) { _, skipped in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(skipped.item.url.path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(skipped.item.url.path)
                                Text(skipped.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: 560, minHeight: 80, maxHeight: 200)
                    }
                }
                HStack {
                    if let batch = result.batch {
                        Button("Undo") { model.undo(batch) }
                    }
                    Button("Done") { model.finish() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)
            if model.isRunning {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("This app is running. Quit it before removing it.")
                    Spacer()
                    Button("Quit App") { model.quitSelectedApp() }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            Divider()
            if model.items.isEmpty {
                Text("Nothing found.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.groups) { group in
                        ItemGroupRow(group: group,
                                     toggleItem: { model.toggle($0) },
                                     setCategory: { model.setCategory($0, selected: $1) })
                    }
                }
            }
            Divider()
            SelectionBar(allSelected: model.allSelected,
                         summary: model.selectedItems.selectionSummary(verb: "remove"),
                         selectAll: { model.selectAll($0) }) {
                Button("Remove Selected…") { reviewing = model.selectedItems }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectedItems.isEmpty || model.isRunning)
                Button("Remove All…") { reviewing = model.items }
                    .disabled(model.items.isEmpty || model.isRunning)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var header: some View {
        if let app = model.selection {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.title2.bold())
                    Text([app.bundleID, app.version, model.usageText(app)].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(ByteFormat.string(model.items.totalSize))
                    .font(.title3)
                    .monospacedDigit()
            }
        }
    }
}
