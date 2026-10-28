import AppKit
import QuickLookThumbnailing
import SwiftUI
import TidyCore

struct ClutterView: View {
    @ObservedObject var model: ClutterModel
    @State private var showingReview = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(12)
            Divider()
            content
        }
        .navigationTitle("Clutter")
        .sheet(isPresented: $showingReview) {
            ReviewSheet(title: "Move these files to quarantine?",
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
                ForEach(ClutterModel.Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(isBusy)
            Text("in \(model.rootsDescription)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Choose Folders…") { model.chooseFolders() }
                .disabled(isBusy)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            VStack(spacing: 14) {
                Image(systemName: model.mode == .similar ? "photo.on.rectangle" : "doc.on.doc")
                    .font(.system(size: 56))
                    .foregroundColor(.accentColor)
                Text(idleDescription)
                    .font(.title3)
                Text("These are your own files, so nothing is selected for you.")
                    .foregroundStyle(.secondary)
                Text("App data (like ~/Library) and project dependencies (like node_modules) are left out, unless you choose those folders.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Scan") { model.scan() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .scanning(let count, let path):
            VStack(spacing: 12) {
                ProgressView()
                Text("\(count) items checked")
                    .monospacedDigit()
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
            VStack(spacing: 0) {
                switch model.mode {
                case .duplicates: duplicatesList
                case .similar: similarList
                case .large: largeList
                }
                Divider()
                footer
                    .padding(12)
            }
        case .cleaning:
            ProgressView("Moving files to quarantine…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done(let result):
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 56))
                    .foregroundColor(.green)
                Text("Moved \(result.removed.count) files (\(ByteFormat.string(result.freedBytes))) to quarantine")
                    .font(.title2.bold())
                if !result.skipped.isEmpty {
                    Text("\(result.skipped.count) files were skipped because they were in use, protected or already gone.")
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

    @ViewBuilder
    private var duplicatesList: some View {
        if model.duplicateGroups.isEmpty {
            Text("No duplicates found.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(model.duplicateGroups) { group in
                    Section {
                        ForEach(group.files) { file in
                            DuplicateRow(file: file,
                                         isSelected: model.selected.contains(file.id),
                                         toggle: { model.toggle(file) })
                        }
                    } header: {
                        HStack {
                            Text(Self.title(of: group))
                                .fontWeight(.semibold)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(Self.detail(of: group))
                                .foregroundStyle(.secondary)
                            if model.groupsLosingEveryCopy.contains(where: { $0.id == group.id }) {
                                Label("Keep at least one copy", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Copies are identical byte for byte, whatever they're called and wherever they are.
    private static func title(of group: DuplicateGroup) -> String {
        group.sharedName ?? "\(group.files.count) files with identical contents"
    }

    private static func detail(of group: DuplicateGroup) -> String {
        let size = ByteFormat.string(group.size)
        if group.sharedName == nil { return "\(size) each, under different names" }
        return "\(group.files.count) identical copies, \(size) each"
    }

    private var idleDescription: String {
        switch model.mode {
        case .duplicates: return "Find files with identical contents (1 MB and up)."
        case .similar: return "Find photos that look alike, such as bursts and edited or resized copies."
        case .large: return "Find files of 100 MB and up, and ones you haven't changed in a year."
        }
    }

    @ViewBuilder
    private var similarList: some View {
        if model.similarGroups.isEmpty {
            Text("No similar photos found.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(model.similarGroups) { group in
                    Section {
                        ForEach(group.photos) { photo in
                            SimilarPhotoRow(photo: photo,
                                            isBest: photo.id == group.best.id,
                                            isSelected: model.selected.contains(photo.id),
                                            toggle: { model.toggle(photo.item) })
                        }
                    } header: {
                        HStack {
                            Text("\(group.photos.count) similar photos")
                                .fontWeight(.semibold)
                            Text("\(ByteFormat.string(group.reclaimableBytes)) if you keep only the best")
                                .foregroundStyle(.secondary)
                            if model.similarGroupsLosingEveryPhoto.contains(where: { $0.id == group.id }) {
                                Label("Keep at least one photo", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var largeList: some View {
        if model.largeItems.isEmpty {
            Text("No large files found.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(model.largeGroups) { group in
                    ItemGroupRow(group: group,
                                 toggleItem: { model.toggle($0) },
                                 setCategory: { model.setCategory($0, selected: $1) })
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(model.selectedItems.count) selected · \(ByteFormat.string(model.selectedItems.totalSize))")
            if model.mode == .duplicates {
                Text("· \(ByteFormat.string(model.wastedBytes)) in extra copies")
                    .foregroundStyle(.secondary)
            }
            if model.mode == .similar {
                Text("· \(ByteFormat.string(model.reclaimablePhotoBytes)) if you keep the best of each")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.mode == .duplicates {
                Button("Select All but Oldest") { model.selectAllButOldest() }
            }
            if model.mode == .similar {
                Button("Select All but Best") { model.selectAllButBest() }
            }
            Button("Clear") { model.clearSelection() }
                .disabled(model.selected.isEmpty)
            Button("Scan Again") { model.scan() }
            Button("Review & Clean…") { showingReview = true }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedItems.isEmpty || !model.keepsOneOfEach)
        }
    }
}

private struct DuplicateRow: View {
    let file: ScanItem
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Self.details(of: file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(file.url.path)
            Spacer()
            Text(ByteFormat.string(file.size))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
        }
    }

    /// Where the copy is, and when it last changed.
    private static func details(of file: ScanItem) -> String {
        let folder = DisplayPath.folder(of: file.url)
        guard let modified = file.lastModified else { return folder }
        return folder + " · Modified " + modified.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct SimilarPhotoRow: View {
    let photo: SimilarPhoto
    let isBest: Bool
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                .labelsHidden()
            PhotoThumbnail(url: photo.item.url)
            VStack(alignment: .leading, spacing: 2) {
                Text(photo.item.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(photo.item.url.path)
                Text("\(photo.pixelWidth) × \(photo.pixelHeight)" + (isBest ? " · Best" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(ByteFormat.string(photo.item.size))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([photo.item.url]) }
        }
    }
}

/// A Quick Look thumbnail, loaded when the row appears.
private struct PhotoThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.15))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: 80, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 80, height: 60),
                                                       scale: 2, representationTypes: .thumbnail)
            if let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                image = thumbnail.nsImage
            }
        }
    }
}
