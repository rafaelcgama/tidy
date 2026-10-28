import AppKit
import Combine
import TidyCore

@MainActor
final class SpaceMapModel: ObservableObject {
    enum Phase {
        case idle
        case scanning(count: Int, path: String?)
        case ready
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var root = FileManager.default.homeDirectoryForCurrentUser
    /// The folders the user has drilled into; the first is the scanned root.
    @Published private(set) var path: [DiskNode] = []
    @Published var errorMessage: String?
    private var task: Task<Void, Never>?

    var current: DiskNode? { path.last }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        panel.prompt = "Map"
        if panel.runModal() == .OK, let url = panel.url {
            root = url
            scan()
        }
    }

    func scan() {
        task?.cancel()
        path = []
        phase = .scanning(count: 0, path: nil)
        let root = self.root
        task = Task {
            do {
                let tree = try await SizeTreeBuilder().build(at: root) { progress in
                    Task { @MainActor in
                        if case .scanning = self.phase {
                            self.phase = .scanning(count: progress.completed, path: progress.currentPath)
                        }
                    }
                }
                path = [tree]
                phase = .ready
            } catch is CancellationError {
                phase = .idle
            } catch {
                errorMessage = error.localizedDescription
                phase = .idle
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func open(_ node: DiskNode) {
        guard node.isDirectory, !node.children.isEmpty else { return }
        path.append(node)
    }

    func goUp(to index: Int) {
        guard index < path.count else { return }
        path.removeSubrange((index + 1)...)
    }

    func reveal(_ node: DiskNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }
}
