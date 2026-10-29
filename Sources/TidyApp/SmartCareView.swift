import SwiftUI
import TidyCore

/// One scan across cleanup and protection, with a single report before anything changes.
struct SmartCareView: View {
    @ObservedObject var model: SmartCareModel
    @ObservedObject var reminders: ReminderModel
    @Binding var selection: Module?
    @State private var reviewing: SmartCareReport?

    var body: some View {
        content
            .navigationTitle("Smart Care")
            .sheet(isPresented: reviewShown) {
                if let report = reviewing {
                    ReviewSheet(title: "Clean this junk?",
                                actionTitle: "Move to Quarantine",
                                items: report.selectedCleanup,
                                retentionDays: model.store.retentionDays) {
                        reviewing = nil
                        model.clean(report)
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
                Text("One scan for junk, package caches, login items and browser settings.")
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
                ForEach(reminders.due) { due in
                    HStack {
                        Image(systemName: "calendar.badge.clock")
                        Text(due.text)
                        if due.scan == .malware {
                            Button("Open Malware Scan") { selection = .malware }
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

    private func reportView(_ report: SmartCareReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card(title: "Cleanup", symbol: "trash.circle.fill", tint: .blue) {
                    if report.selectedCleanup.isEmpty {
                        Text("No junk to clean.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(ByteFormat.string(report.selectedCleanup.totalSize)) of caches, logs and build files in \(report.selectedCleanup.count) items.")
                        HStack {
                            Button("Review & Clean…") { reviewing = report }
                                .keyboardShortcut(.defaultAction)
                            Button("Choose Items in System Junk") { selection = .systemJunk }
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
                    Text("Which apps to remove needs your judgment, so Smart Care leaves that to the Uninstaller, along with what removed apps left behind.")
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
