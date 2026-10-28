import SwiftUI
import TidyCore

/// Threat heuristics: suspicious launch jobs and browser settings locked by a policy.
struct ProtectionView: View {
    @ObservedObject var model: ProtectionModel
    @State private var pendingRemoval: Finding?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(summary)
                    .font(.headline)
                Spacer()
                Button("Scan Again") { model.refresh() }
                    .disabled(model.isLoading)
            }
            .padding(12)
            Divider()
            if model.isLoading && !model.hasLoaded {
                ProgressView("Checking login items, agents and browser policies…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.findings.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 56))
                        .foregroundColor(.green)
                    Text("Nothing suspicious found.")
                        .font(.title3)
                    Text("Tidy checks how things start on your Mac and whether your browser settings are locked. It doesn't replace macOS's built-in XProtect.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.findings) { finding in
                    FindingRow(finding: finding,
                               canRemove: model.canRemove(finding.url),
                               reveal: { model.reveal(finding.url) },
                               remove: { pendingRemoval = finding })
                }
            }
            if let notice = model.notice {
                Divider()
                HStack {
                    Text(notice)
                    Spacer()
                    Button("Undo") { model.undoLast() }
                }
                .padding(12)
            }
        }
        .navigationTitle("Protection")
        .onAppear {
            if !model.hasLoaded { model.refresh() }
        }
        .confirmationDialog("Stop this from starting at login?",
                            isPresented: removalShown,
                            presenting: pendingRemoval) { finding in
            Button("Move to Quarantine", role: .destructive) {
                model.remove(finding.url, name: finding.title)
            }
        } message: { finding in
            Text("\(finding.url.path) will be moved to quarantine. You can undo this for \(model.store.retentionDays) days.")
        }
        .alert("Something went wrong", isPresented: errorShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var summary: String {
        if !model.hasLoaded { return "Checking…" }
        if model.findings.isEmpty { return "No findings" }
        return "\(model.findings.count) findings, \(model.dangerCount) serious"
    }

    private var removalShown: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }
}

private struct FindingRow: View {
    let finding: Finding
    let canRemove: Bool
    let reveal: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(finding.title)
                    .font(.headline)
                ForEach(finding.reasons, id: \.self) { reason in
                    Text("• \(reason)")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(finding.url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack {
                    Button("Reveal in Finder", action: reveal)
                    if canRemove {
                        Button("Move to Quarantine…", action: remove)
                    } else {
                        Text("Tidy doesn't remove this one itself.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
    }

    private var symbol: String {
        switch finding.severity {
        case .danger: return "xmark.shield.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .notice: return "info.circle.fill"
        }
    }

    private var color: Color {
        switch finding.severity {
        case .danger: return .red
        case .warning: return .orange
        case .notice: return .blue
        }
    }
}
