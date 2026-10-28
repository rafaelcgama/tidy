import SwiftUI
import TidyCore

struct CloudView: View {
    @ObservedObject var model: CloudModel
    @State private var showingReview = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(12)
            Divider()
            if model.folders.isEmpty {
                Text("No iCloud Drive, Dropbox, Google Drive, OneDrive or Box folders found on this Mac.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
            if let notice = model.notice {
                Divider()
                Text(notice)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .navigationTitle("Cloud")
        .sheet(isPresented: $showingReview) {
            ReviewSheet(title: "Move these local copies to quarantine?",
                        actionTitle: "Move to Quarantine",
                        items: model.selectedItems,
                        retentionDays: model.store.retentionDays) {
                showingReview = false
                model.clean()
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

    private var isBusy: Bool {
        switch model.phase {
        case .scanning, .cleaning: return true
        default: return false
        }
    }

    private var header: some View {
        HStack {
            Picker("", selection: $model.mode) {
                ForEach(CloudModel.Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(isBusy)
            Text(model.folders.map(\.name).joined(separator: ", "))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            VStack(spacing: 14) {
                Image(systemName: "icloud")
                    .font(.system(size: 56))
                    .foregroundColor(.accentColor)
                Text(model.mode == .large
                     ? "List big files in your cloud folders, and free the space of ones you've downloaded."
                     : "Find files in Documents, Desktop and Downloads that you also keep in the cloud.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                Text("Reading never downloads cloud-only files.")
                    .foregroundStyle(.secondary)
                Button("Scan") { model.scan() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .scanning(let path):
            VStack(spacing: 12) {
                ProgressView()
                Text(path ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Stop") { model.cancel() }
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .results:
            if model.mode == .large {
                largeTable
            } else {
                copiesList
            }
        case .cleaning:
            ProgressView("Moving local copies to quarantine…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done(let result):
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 56))
                    .foregroundColor(.green)
                Text("Moved \(result.removed.count) local copies (\(ByteFormat.string(result.freedBytes))) to quarantine")
                    .font(.title2.bold())
                Text("The originals are still in your cloud folders.")
                    .foregroundStyle(.secondary)
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

    @ViewBuilder
    private var largeTable: some View {
        if model.largeFiles.isEmpty {
            Text("No files of 100 MB or more in your cloud folders.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(model.largeFiles) {
                TableColumn("Name") { file in
                    Text(file.url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(file.url.path)
                }
                TableColumn("Service") { file in
                    Text(file.provider)
                }
                .width(min: 100, ideal: 140)
                TableColumn("Size") { file in
                    Text(ByteFormat.string(file.size))
                        .monospacedDigit()
                }
                .width(min: 70, ideal: 80)
                TableColumn("On this Mac") { file in
                    if file.isDownloaded {
                        Button("Remove Download") { model.removeDownload(file) }
                    } else {
                        Text("Cloud only")
                            .foregroundStyle(.secondary)
                    }
                }
                .width(min: 120, ideal: 140)
            }
        }
    }

    @ViewBuilder
    private var copiesList: some View {
        if model.copies.isEmpty {
            Text("No local copies of cloud files found.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                List {
                    ForEach(model.copies) { copy in
                        Section {
                            ForEach(copy.localCopies) { item in
                                HStack {
                                    Toggle("", isOn: Binding(get: { model.selected.contains(item.id) },
                                                             set: { _ in model.toggle(item) }))
                                        .labelsHidden()
                                    Text(item.url.path)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(item.url.path)
                                    Spacer()
                                    Text(ByteFormat.string(item.size))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } header: {
                            Text("In the cloud: \(copy.cloudFile.url.path)")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                Divider()
                HStack {
                    Text("\(model.selectedItems.count) selected · \(ByteFormat.string(model.selectedItems.totalSize))")
                    Spacer()
                    Button("Select All Local Copies") { model.selectAllLocalCopies() }
                    Button("Scan Again") { model.scan() }
                    Button("Review & Clean…") { showingReview = true }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.selectedItems.isEmpty)
                }
                .padding(12)
            }
        }
    }
}
