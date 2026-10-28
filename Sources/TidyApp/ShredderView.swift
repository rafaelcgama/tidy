import AppKit
import SwiftUI
import TidyCore
import UniformTypeIdentifiers

/// Overwrites and deletes files you hand it, after you type a confirmation. The one thing in Tidy
/// that can't be undone.
struct ShredderView: View {
    @ObservedObject var model: ShredderModel
    @State private var dropTargeted = false

    var body: some View {
        content
            .navigationTitle("Shredder")
            .onAppear {
                if model.fileVaultOn == nil { model.checkFileVault() }
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
        case .choosing:
            choosingView
        case .shredding(let done, let total):
            VStack(spacing: 12) {
                ProgressView(value: Double(min(done, total)), total: Double(max(total, 1)))
                    .frame(maxWidth: 360)
                Text("Shredding… \(ByteFormat.string(done)) of \(ByteFormat.string(total))")
                    .monospacedDigit()
                Text("Overwriting can't be stopped halfway through a file, so this runs to the end.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done(let result):
            doneView(result)
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    private var choosingView: some View {
        VStack(spacing: 0) {
            if model.chosen.isEmpty {
                dropZone
            } else {
                List {
                    ForEach(model.chosen, id: \.path) { url in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                                .frame(width: 20, height: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent)
                                Text(url.deletingLastPathComponent().path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if let refusal = model.refusal(for: url) {
                                    Label(refusal, systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            }
                            Spacer()
                            Button {
                                model.remove(url)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .help("Don't shred this")
                        }
                    }
                }
                .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted, perform: drop)
                Divider()
                confirmBar
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 16) {
            Image(systemName: "scissors")
                .font(.system(size: 64))
                .foregroundColor(dropTargeted ? Color.accentColor : Color.secondary)
            Text("Drop files or folders here to destroy them for good.")
                .font(.title3)
            Text("Shredding overwrites each file with random data, then deletes it. Unlike everything else in Tidy, it can't be undone and nothing goes to quarantine.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Button("Choose Files…") { model.choose() }
                .controlSize(.large)
            caveat
                .frame(maxWidth: 520)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(dropTargeted ? Color.accentColor : Color.clear, style: StrokeStyle(lineWidth: 2, dash: [6]))
            .padding(12))
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted, perform: drop)
    }

    /// What overwriting can't promise, said plainly.
    private var caveat: some View {
        VStack(spacing: 6) {
            Text("On SSDs, in iCloud, and in Time Machine backups or snapshots, old data can outlive the overwrite. Encryption is what keeps it unreadable.")
            switch model.fileVaultOn {
            case .some(true):
                Label("FileVault is on, so this Mac's disk is encrypted.", systemImage: "lock.fill")
            case .some(false):
                Label("FileVault is off. Turn it on in System Settings › Privacy & Security.", systemImage: "lock.open")
                    .foregroundColor(.orange)
            case .none:
                EmptyView()
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }

    private var confirmBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let plan = model.plan {
                if plan.accepted.isEmpty {
                    Text("None of these can be shredded.")
                        .fontWeight(.medium)
                } else {
                    Text(summary(of: plan))
                        .fontWeight(.medium)
                }
            } else {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Counting files…")
                }
            }
            caveat
                .multilineTextAlignment(.leading)
            HStack {
                Button("Add More…") { model.choose() }
                Button("Clear") { model.clear() }
                Spacer()
                TextField("Type \(ShredderModel.confirmationWord) to confirm", text: $model.confirmation)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit { model.shred() }
                Button("Shred", role: .destructive) { model.shred() }
                    .disabled(!model.canShred)
            }
        }
        .padding(12)
    }

    private func summary(of plan: Shredder.Plan) -> String {
        let files = plan.fileCount == 1 ? "1 file" : "\(plan.fileCount) files"
        let folders = plan.folderCount == 0 ? "" : plan.folderCount == 1 ? " and 1 folder" : " and \(plan.folderCount) folders"
        return files + folders + ", " + ByteFormat.string(plan.totalBytes) + ", will be overwritten and deleted. This can't be undone."
    }

    private func doneView(_ result: Shredder.Result) -> some View {
        VStack(spacing: 14) {
            Image(systemName: result.failed.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.system(size: 56))
                .foregroundColor(result.failed.isEmpty ? Color.green : Color.orange)
            Text(result.shredded.count == 1 ? "Shredded 1 item" : "Shredded \(result.shredded.count) items")
                .font(.title2.bold())
            Text("\(ByteFormat.string(result.bytesOverwritten)) overwritten with random data and deleted.")
                .foregroundStyle(.secondary)
            if !result.failed.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Not shredded:")
                        .fontWeight(.medium)
                    ForEach(result.failed, id: \.self) { failure in
                        Text("\(failure.url.path): \(failure.reason)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
            }
            Button("Done") { model.finish() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        let model = self.model
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.add([url]) }
            }
        }
        return true
    }
}
