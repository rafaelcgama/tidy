import AppKit
import SwiftUI
import TidyCore

struct UninstallerView: View {
    @ObservedObject var model: UninstallerModel
    @State private var showingReview = false

    var body: some View {
        HSplitView {
            appList
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
            detail
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Uninstaller")
        .onAppear {
            if model.apps.isEmpty { model.loadApps() }
        }
        .sheet(isPresented: $showingReview) {
            ReviewSheet(title: model.selectedApp.map { "Remove \($0.name)?" } ?? "Remove these leftovers?",
                        actionTitle: "Move to Quarantine",
                        items: model.selectedItems,
                        retentionDays: model.store.retentionDays) {
                showingReview = false
                model.remove()
            } onCancel: {
                showingReview = false
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

    private var appList: some View {
        VStack(spacing: 0) {
            TextField("Search apps", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            List(selection: $model.selection) {
                Section {
                    Label("Leftovers of removed apps", systemImage: "questionmark.folder")
                        .tag(UninstallerModel.Selection.orphans)
                }
                Section("Applications") {
                    ForEach(model.filteredApps) { app in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                .resizable()
                                .frame(width: 20, height: 20)
                            VStack(alignment: .leading) {
                                Text(app.name)
                                if let version = app.version {
                                    Text(version)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .tag(UninstallerModel.Selection.app(app))
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
                Text("Pick an app to remove it and everything it left behind,")
                Text("or look for leftovers of apps you already deleted.")
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
            HStack {
                Text("\(model.selectedItems.count) items selected · \(ByteFormat.string(model.selectedItems.totalSize))")
                Spacer()
                Button("Review & Remove…") { showingReview = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectedItems.isEmpty || model.isRunning)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var header: some View {
        if let app = model.selectedApp {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.title2.bold())
                    Text([app.bundleID, app.version].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(ByteFormat.string(model.items.totalSize))
                    .font(.title3)
                    .monospacedDigit()
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Leftovers of removed apps")
                    .font(.title2.bold())
                Text("These look like data from apps that are no longer in Applications. Nothing is preselected: apps installed elsewhere and helper tools can look the same, so check each item before you remove it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
