import SwiftUI
import TidyCore

struct ScanCleanView: View {
    /// The words and icon that make the generic screen fit one module.
    struct Copy {
        let title: String
        let symbol: String
        let blurb: String
        var choosesFolders = false
        /// Shown under the blurb before scanning.
        var note: String?
        var emptyMessage = "No junk found."
    }

    @ObservedObject var model: ScanCleanModel
    let copy: Copy
    @State private var showingReview = false

    var body: some View {
        content
            .navigationTitle(copy.title)
            .sheet(isPresented: $showingReview) {
                ReviewSheet(title: "Move these items to quarantine?",
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

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            idleView
        case .scanning(let path):
            scanningView(path: path)
        case .results:
            resultsView
        case .cleaning:
            ProgressView("Moving items to quarantine…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done(let result):
            doneView(result)
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }

    private var idleView: some View {
        VStack(spacing: 16) {
            Image(systemName: copy.symbol)
                .font(.system(size: 64))
                .foregroundColor(.accentColor)
            Text(copy.blurb)
                .font(.title3)
                .multilineTextAlignment(.center)
            if let note = copy.note {
                Text(note)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if copy.choosesFolders {
                HStack {
                    Text("Projects in \(model.rootsDescription)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose Folders…") { model.chooseFolders() }
                }
            }
            Text("Nothing is removed until you review it. Removed items stay in quarantine for \(model.store.retentionDays) days, so you can undo.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let notice = model.notice {
                Text(notice)
            }
            Button("Scan") { model.scan() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scanningView(path: String?) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(path ?? "Starting…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Stop") { model.cancelScan() }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var resultsView: some View {
        if model.items.isEmpty {
            VStack(spacing: 12) {
                Text(copy.emptyMessage)
                    .font(.title3)
                Text("If you expected results, give Tidy Full Disk Access in System Settings › Privacy & Security.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Scan Again") { model.scan() }
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                List {
                    ForEach(model.groups) { group in
                        ItemGroupRow(group: group,
                                     toggleItem: { model.toggle($0) },
                                     setCategory: { model.setCategory($0, selected: $1) })
                    }
                }
                Divider()
                HStack {
                    Text("\(model.selectedItems.count) items selected · \(ByteFormat.string(model.selectedSize))")
                    if let blocker = model.blocker {
                        Label(blocker, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    }
                    Spacer()
                    Button("Scan Again") { model.scan() }
                    Button("Review & Clean…") { showingReview = true }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.selectedItems.isEmpty || model.blocker != nil)
                }
                .padding(12)
            }
        }
    }

    private func doneView(_ result: CleanResult) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 56))
                .foregroundColor(.green)
            Text("Moved \(ByteFormat.string(result.freedBytes)) to quarantine")
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
