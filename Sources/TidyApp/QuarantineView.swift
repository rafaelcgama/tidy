import SwiftUI
import TidyCore

/// Each clean of the last weeks, what it moved, Put Back, and deleting it for good sooner, one clean
/// at a time or several ticked together.
struct QuarantineView: View {
    @ObservedObject var model: QuarantineModel
    @State private var expanded: Set<String> = []
    /// The ticked cleans, by id.
    @State private var chosen: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            if model.batches.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                    Text("Quarantine is empty.")
                        .font(.title3)
                    Text("Whatever Tidy cleans waits here for \(model.store.retentionDays) days, so you can put it back.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.batches) { batch in
                    DisclosureGroup(isExpanded: expansion(of: batch.id)) {
                        ForEach(batch.entries, id: \.self) { entry in
                            HStack {
                                Text(entry.originalPath)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(entry.originalPath)
                                Spacer()
                                Text(ByteFormat.string(entry.size))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    } label: {
                        HStack {
                            Toggle("", isOn: choice(of: batch.id))
                                .labelsHidden()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(batch.date.formatted(date: .abbreviated, time: .shortened))
                                Text("\(batch.entries.count) items, \(ByteFormat.string(batch.totalSize)) · " + (model.daysLeft(batch) > 0
                                     ? "deleted for good in \(model.daysLeft(batch)) days" : "due to be deleted for good"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.restoring == batch.id {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Button("Show in Finder") { model.reveal(batch) }
                            Button("Delete Now…") { model.pendingDeletion = [batch] }
                                .disabled(busy)
                            Button("Put Back") { model.restore([batch]) }
                                .disabled(busy)
                        }
                    }
                }
                Divider()
                HStack {
                    Button(chosenBatches.count == model.batches.count ? "Deselect All" : "Select All") {
                        chosen = chosenBatches.count == model.batches.count ? [] : Set(model.batches.map(\.id))
                    }
                    Text(chosenBatches.isEmpty
                         ? "Tick cleans to put back or delete several at once."
                         : "\(Self.cleans(chosenBatches.count)) selected, \(ByteFormat.string(chosenBatches.reduce(0) { $0 + $1.totalSize }))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Put Back Selected") { model.restore(chosenBatches) }
                        .disabled(chosenBatches.isEmpty || busy)
                    Button("Delete Selected…") { model.pendingDeletion = chosenBatches }
                        .disabled(chosenBatches.isEmpty || busy)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                Text(Self.cleans(model.batches.count) + ", \(ByteFormat.string(model.totalSize)) in all. Each is deleted for good \(model.store.retentionDays) days after it was cleaned; Delete Now, Delete Selected and Empty Quarantine do it sooner, and that can't be undone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            if let notice = model.notice {
                Divider()
                Text(notice)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .navigationTitle("Quarantine")
        .toolbar {
            if model.deleting {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Empty Quarantine…") { model.pendingDeletion = model.batches }
                .disabled(model.batches.isEmpty || model.deleting || model.restoring != nil)
            Button("Refresh") { model.refresh() }
        }
        .onAppear { model.refresh() }
        .sheet(isPresented: deletionShown) {
            if let batches = model.pendingDeletion {
                DeleteForGoodSheet(batches: batches, emptiesAll: batches.count == model.batches.count && batches.count > 1,
                                   needsPassword: model.needsPassword(batches)) {
                    model.deleteForGood(batches)
                } onCancel: {
                    model.pendingDeletion = nil
                }
            }
        }
        .alert("Something went wrong", isPresented: errorShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var busy: Bool { model.restoring != nil || model.deleting }

    /// The ticked cleans that are still in quarantine.
    private var chosenBatches: [QuarantineBatch] { model.batches.filter { chosen.contains($0.id) } }

    /// "1 clean" or "3 cleans".
    private static func cleans(_ count: Int) -> String { count == 1 ? "1 clean" : "\(count) cleans" }

    private func choice(of id: String) -> Binding<Bool> {
        Binding(get: { chosen.contains(id) },
                set: { isOn in
                    if isOn { chosen.insert(id) } else { chosen.remove(id) }
                })
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    private var deletionShown: Binding<Bool> {
        Binding(get: { model.pendingDeletion != nil }, set: { if !$0 { model.pendingDeletion = nil } })
    }

    private func expansion(of id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) },
                set: { isOpen in
                    if isOpen { expanded.insert(id) } else { expanded.remove(id) }
                })
    }
}

/// Shows exactly what will be deleted for good, with sizes, before anything is.
private struct DeleteForGoodSheet: View {
    let batches: [QuarantineBatch]
    let emptiesAll: Bool
    let needsPassword: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var entries: [QuarantineEntry] { batches.flatMap(\.entries) }
    private var totalSize: Int64 { batches.reduce(0) { $0 + $1.totalSize } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(emptiesAll ? "Empty Quarantine?" : "Delete these items for good?")
                .font(.title2.bold())
            Text("\(entries.count) items, \(ByteFormat.string(totalSize)). They'll be deleted for good and can't be put back.")
                .foregroundStyle(.secondary)
            if needsPassword {
                Label("Some of them belong to the system, so macOS asks for an administrator's password.", systemImage: "lock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            List {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    HStack {
                        Text(entry.originalPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(entry.originalPath)
                        Spacer()
                        Text(ByteFormat.string(entry.size))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 240)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Delete for Good", role: .destructive, action: onConfirm)
            }
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 400)
    }
}
