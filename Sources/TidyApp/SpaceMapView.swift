import SwiftUI
import TidyCore

struct SpaceMapView: View {
    @ObservedObject var model: SpaceMapModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(12)
            Divider()
            content
        }
        .navigationTitle("Space Map")
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

    private var isScanning: Bool {
        if case .scanning = model.phase { return true }
        return false
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            if model.path.isEmpty {
                Text(model.root.path)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(model.path.enumerated()), id: \.element.id) { index, node in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
                Button(index == 0 ? node.url.path : node.name) { model.goUp(to: index) }
                    .buttonStyle(.link)
            }
            if let current = model.current {
                Text(ByteFormat.string(current.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
            }
            Spacer()
            Button("Choose Folder…") { model.chooseFolder() }
                .disabled(isScanning)
            Button("Rescan") { model.scan() }
                .disabled(isScanning)
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            VStack(spacing: 14) {
                Image(systemName: "chart.pie")
                    .font(.system(size: 56))
                    .foregroundColor(.accentColor)
                Text("See what is taking up space in \(model.root.lastPathComponent).")
                    .font(.title3)
                Text("Mapping only reads your files; it never changes them.")
                    .foregroundStyle(.secondary)
                Button("Map \(model.root.lastPathComponent)") { model.scan() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .scanning(let count, let path):
            VStack(spacing: 12) {
                ProgressView()
                Text("\(count) items")
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
        case .ready:
            if let current = model.current {
                HSplitView {
                    TreemapView(node: current,
                                open: { model.open($0) },
                                reveal: { model.reveal($0) })
                        .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                    list(for: current)
                        .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
                }
            }
        }
    }

    private func list(for node: DiskNode) -> some View {
        List(node.children) { child in
            HStack {
                Image(systemName: child.isDirectory ? "folder" : (child.isAggregate ? "square.stack" : "doc"))
                    .foregroundStyle(.secondary)
                Text(child.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(ByteFormat.string(child.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.open(child) }
            .contextMenu {
                if child.isDirectory {
                    Button("Open") { model.open(child) }
                }
                if !child.isAggregate {
                    Button("Reveal in Finder") { model.reveal(child) }
                }
            }
        }
    }
}

/// One level of the size tree as a squarified treemap. Click a folder to go into it.
struct TreemapView: View {
    let node: DiskNode
    let open: (DiskNode) -> Void
    let reveal: (DiskNode) -> Void

    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .green, .indigo, .red, .cyan, .brown]

    var body: some View {
        GeometryReader { geometry in
            let bounds = TreemapRect(x: 0, y: 0, width: geometry.size.width, height: geometry.size.height)
            let rects = Treemap.layout(node.children.map { Double($0.size) }, in: bounds)
            ZStack(alignment: .topLeading) {
                ForEach(node.children.indices, id: \.self) { index in
                    tile(node.children[index], rect: rects[index], color: color(for: node.children[index], index: index))
                }
            }
        }
        .padding(8)
    }

    private func color(for child: DiskNode, index: Int) -> Color {
        if child.isAggregate { return Color.gray.opacity(0.45) }
        if !child.isDirectory { return Color.gray }
        return Self.palette[index % Self.palette.count]
    }

    @ViewBuilder
    private func tile(_ child: DiskNode, rect: TreemapRect, color: Color) -> some View {
        if rect.width >= 1, rect.height >= 1 {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.gradient)
                if rect.width > 60, rect.height > 30 {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(child.name)
                            .font(.caption.bold())
                            .lineLimit(1)
                        Text(ByteFormat.string(child.size))
                            .font(.caption2)
                            .monospacedDigit()
                    }
                    .foregroundColor(.white)
                    .padding(4)
                }
            }
            .frame(width: max(0, rect.width - 2), height: max(0, rect.height - 2))
            .offset(x: rect.x + 1, y: rect.y + 1)
            .help("\(child.name), \(ByteFormat.string(child.size))")
            .onTapGesture {
                if child.isDirectory { open(child) }
            }
            .contextMenu {
                if child.isDirectory {
                    Button("Open") { open(child) }
                }
                if !child.isAggregate {
                    Button("Reveal in Finder") { reveal(child) }
                }
            }
        }
    }
}
