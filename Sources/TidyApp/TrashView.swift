import AppKit
import Combine
import SwiftUI
import TidyCore

/// What's in the Trash, for Smart Care and System Junk, and emptying it for good after a confirmation.
@MainActor
final class TrashModel: ObservableObject {
    /// Nil until it's looked, or when macOS doesn't let Tidy look.
    @Published private(set) var items: [ScanItem]?
    @Published private(set) var needsFullDiskAccess = false
    @Published private(set) var emptying = false
    @Published private(set) var notice: String?
    /// The confirmation that lists everything before it's deleted.
    @Published var confirming = false

    private let trash = Trash()

    func refresh() {
        let trash = self.trash
        Task {
            let found = await Task.detached { trash.items() }.value
            items = found
            needsFullDiskAccess = found == nil
        }
    }

    func empty() {
        confirming = false
        guard let chosen = items, !chosen.isEmpty else { return }
        let trash = self.trash
        emptying = true
        notice = nil
        Task {
            do {
                let result = try await Task.detached { try trash.empty(chosen) }.value
                var text = "Deleted \(Self.count(result.deleted)) (\(ByteFormat.string(result.deleted.totalSize))) for good."
                if let first = result.skipped.first {
                    text += " \(result.skipped.count) couldn't be deleted (\(first.item.url.lastPathComponent): \(first.reason))."
                }
                notice = text
            } catch {
                notice = "Nothing was deleted: Tidy couldn't write its log (\(error.localizedDescription))."
            }
            emptying = false
            refresh()
        }
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    /// "1 item" or "3 items".
    nonisolated static func count(_ items: [ScanItem]) -> String {
        items.count == 1 ? "1 item" : "\(items.count) items"
    }
}

/// The Trash on top of System Junk: emptying it is a cleanup of its own, since it skips quarantine.
struct TrashBar: View {
    @ObservedObject var model: TrashModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label("Trash", systemImage: "trash")
                .font(.headline)
            TrashSummary(model: model)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// The Trash's size with Empty Trash, or why Tidy can't see it.
struct TrashSummary: View {
    @ObservedObject var model: TrashModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if model.needsFullDiskAccess {
                    Text("Tidy needs Full Disk Access to see what's in the Trash.")
                        .foregroundStyle(.secondary)
                    Button("Open Settings") { model.openFullDiskAccessSettings() }
                } else if let items = model.items {
                    if items.isEmpty {
                        Text("The Trash is empty.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(ByteFormat.string(items.totalSize)) in \(TrashModel.count(items)).")
                        Button("Empty Trash…") { model.confirming = true }
                            .disabled(model.emptying)
                    }
                } else {
                    Text("Looking in the Trash…")
                        .foregroundStyle(.secondary)
                }
                if model.emptying {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if let notice = model.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { model.refresh() }
        .sheet(isPresented: $model.confirming) {
            EmptyTrashSheet(items: model.items ?? []) {
                model.empty()
            } onCancel: {
                model.confirming = false
            }
        }
    }
}

/// Lists everything in the Trash, with sizes, before it's deleted for good.
private struct EmptyTrashSheet: View {
    let items: [ScanItem]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Empty the Trash?")
                .font(.title2.bold())
            Text("\(TrashModel.count(items)), \(ByteFormat.string(items.totalSize)). They'll be deleted for good, as Finder's Empty Trash does, and can't be put back.")
                .foregroundStyle(.secondary)
            List(items) { item in
                HStack {
                    Text(item.url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.url.path)
                    Spacer()
                    Text(ByteFormat.string(item.size))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 240)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Empty Trash", role: .destructive, action: onConfirm)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 380)
    }
}
