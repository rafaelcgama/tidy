import SwiftUI
import TidyCore

/// Shows exactly what will be moved, with sizes, before anything changes.
struct ReviewSheet: View {
    let title: String
    let actionTitle: String
    let items: [ScanItem]
    let retentionDays: Int
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @ObservedObject private var helper = AdminHelper.shared

    var body: some View {
        let adminCount = items.filter { AdminAccess.needsAdmin($0.url) }.count
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.bold())
            Text("\(items.count) items, \(ByteFormat.string(items.totalSize)). They go to quarantine for \(retentionDays) days, so you can undo this.")
                .foregroundStyle(.secondary)
            if adminCount > 0 {
                Label(helper.isEnabled
                      ? "\(adminCount) of them need administrator rights, so Tidy's admin helper moves those."
                      : "\(adminCount) of them need administrator rights, so macOS asks for your password to move those.",
                      systemImage: "lock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Table(items) {
                TableColumn("Path") { item in
                    HStack(spacing: 4) {
                        if AdminAccess.needsAdmin(item.url) {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.secondary)
                                .help("Needs administrator rights")
                        }
                        Text(item.url.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(item.url.path)
                    }
                }
                TableColumn("Category") { item in
                    Text(item.category)
                }
                .width(min: 120, ideal: 150)
                TableColumn("Size") { item in
                    Text(ByteFormat.string(item.size))
                        .monospacedDigit()
                }
                .width(min: 70, ideal: 80)
            }
            .frame(minHeight: 260)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 420)
    }
}
