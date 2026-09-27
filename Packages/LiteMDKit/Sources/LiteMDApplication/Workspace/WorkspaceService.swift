import Foundation
import LiteMDDomain
import Observation

/// 文件树节点。子节点按需加载（spec §80），打开 Workspace 时不读取任何正文。
@MainActor
@Observable
public final class WorkspaceNode: Identifiable {
    public let id = UUID()
    public internal(set) var url: URL
    public let isDirectory: Bool
    /// nil 表示尚未加载。
    public internal(set) var children: [WorkspaceNode]?
    public var isExpanded = false
    public internal(set) var isLoading = false
    /// iCloud 状态（普通本地文件为 `.local`）。
    public internal(set) var cloudStatus: CloudStatus = .local
    /// 每次读取子节点加一。展开与刷新可能同时读取同一目录，只采用最后一次开始的结果。
    @ObservationIgnored var loadGeneration = 0

    @ObservationIgnored
    public internal(set) weak var parent: WorkspaceNode?

    init(url: URL, isDirectory: Bool, parent: WorkspaceNode?) {
        self.url = url.standardizedFileURL
        self.isDirectory = isDirectory
        self.parent = parent
    }

    public var name: String { url.lastPathComponent }
}

/// Workspace：打开文件夹、维护文件树、文件操作（spec §118）。
/// 不强制项目格式，不修改用户的 Markdown 文件结构。
@MainActor
@Observable
public final class WorkspaceService {
    public private(set) var root: WorkspaceNode?
    public var rules = WorkspaceIgnoreRules()

    @ObservationIgnored private let fileSystem: any FileSystem
    @ObservationIgnored private var markdownFileCache: [URL]?
    @ObservationIgnored private var markdownFileTask: Task<[URL], Never>?

    @ObservationIgnored public var onItemMoved: ((URL, URL) -> Void)?
    @ObservationIgnored public var onItemTrashed: ((URL) -> Void)?

    public init(fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
    }

    public var rootURL: URL? { root?.url }

    // MARK: Open

    public func open(_ url: URL) async throws(LiteMDError) {
        guard await fileSystem.isDirectory(at: url) else {
            throw LiteMDError(kind: .workspace, reason: .notFound, fileName: url.lastPathComponent)
        }
        let node = WorkspaceNode(url: url, isDirectory: true, parent: nil)
        node.isExpanded = true
        root = node
        invalidateFileIndex()
        try await loadChildren(of: node)
    }

    public func close() {
        root = nil
        invalidateFileIndex()
    }

    public func contains(_ url: URL) -> Bool {
        guard let rootPath = root?.url.path else { return false }
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    // MARK: Tree

    public func setExpanded(_ node: WorkspaceNode, _ expanded: Bool) {
        node.isExpanded = expanded
        if expanded, node.children == nil {
            Task { try? await loadChildren(of: node) }
        }
    }

    public func loadChildren(of node: WorkspaceNode) async throws(LiteMDError) {
        guard node.isDirectory else { return }
        node.loadGeneration += 1
        let generation = node.loadGeneration
        node.isLoading = true
        defer {
            if node.loadGeneration == generation { node.isLoading = false }
        }

        let entries = try await fileSystem.contentsOfDirectory(at: node.url, rules: rules)
        // 读取期间又开始了新的读取：这份结果已经过时，丢弃。
        guard node.loadGeneration == generation else { return }
        // 文件树只显示 Markdown / 文本文件与图片。
        let visible = entries.filter { entry in
            entry.isDirectory || MarkdownFileType.isDocument(entry.url) || MarkdownFileType.isImage(entry.url)
        }

        // 合并：保留已有节点的展开状态与子节点。
        let existing = Dictionary((node.children ?? []).map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        node.children = visible.map { entry in
            let url = entry.url.standardizedFileURL
            if let current = existing[url], current.isDirectory == entry.isDirectory {
                current.cloudStatus = entry.cloudStatus
                return current
            }
            let child = WorkspaceNode(url: url, isDirectory: entry.isDirectory, parent: node)
            child.cloudStatus = entry.cloudStatus
            return child
        }
    }

    public func node(for url: URL) -> WorkspaceNode? {
        guard let root else { return nil }
        let target = url.standardizedFileURL.path
        if target == root.url.path { return root }
        guard target.hasPrefix(root.url.path + "/") else { return nil }

        var current = root
        while true {
            guard let children = current.children,
                  let next = children.first(where: { target == $0.url.path || target.hasPrefix($0.url.path + "/") }) else {
                return nil
            }
            if next.url.path == target { return next }
            current = next
        }
    }

    /// 重新读取某个已加载的目录。
    public func refreshDirectory(_ url: URL) async {
        guard let node = node(for: url), node.isDirectory, node.children != nil else { return }
        try? await loadChildren(of: node)
    }

    public func refreshAll() async {
        guard let root else { return }
        invalidateFileIndex()
        var queue = [root]
        while !queue.isEmpty {
            let node = queue.removeFirst()
            guard node.children != nil else { continue }
            try? await loadChildren(of: node)
            queue.append(contentsOf: (node.children ?? []).filter { $0.isDirectory && $0.children != nil })
        }
    }

    public func handleFileEvents(_ events: [FileEvent]) async {
        guard root != nil else { return }
        if events.contains(where: { $0.flags.contains(.mustRescan) }) {
            await refreshAll()
            return
        }
        let structural: FileEvent.Flags = [.created, .removed, .renamed]
        var directories = Set<URL>()
        for event in events where !event.flags.isDisjoint(with: structural) && contains(event.url) {
            directories.insert(event.url.deletingLastPathComponent().standardizedFileURL)
            invalidateFileIndex()
        }
        for directory in directories {
            await refreshDirectory(directory)
        }
    }

    // MARK: File index

    /// Workspace 内所有 Markdown 文件（Quick Open、搜索使用），后台枚举并缓存。
    public func allMarkdownFiles() async -> [URL] {
        if let markdownFileCache { return markdownFileCache }
        guard let rootURL else { return [] }
        if let markdownFileTask { return await markdownFileTask.value }

        let fileSystem = self.fileSystem
        let rules = self.rules
        let task = Task { (try? await fileSystem.markdownFiles(under: rootURL, rules: rules)) ?? [] }
        markdownFileTask = task
        let files = await task.value
        // open / close 会清空 markdownFileTask，任务仍相同说明根目录没有变化。
        if markdownFileTask == task {
            markdownFileCache = files
            markdownFileTask = nil
        }
        return files
    }

    /// 新建文件后立即刷新 Quick Open 与双链使用的文件列表。
    public func invalidateMarkdownFileCache() {
        invalidateFileIndex()
    }

    private func invalidateFileIndex() {
        markdownFileCache = nil
        markdownFileTask = nil
    }

    // MARK: File operations

    @discardableResult
    public func createMarkdownFile(in directory: URL, baseName: String = "Untitled") async throws(LiteMDError) -> URL {
        let url = try await UniqueItemNaming.workspace.create(in: directory, baseName: baseName, extension: "md") { url throws(LiteMDError) in
            try await self.fileSystem.createFile(at: url, contents: Data())
        }
        await refreshDirectory(directory)
        invalidateFileIndex()
        return url
    }

    @discardableResult
    public func createFolder(in directory: URL, baseName: String = "New Folder") async throws(LiteMDError) -> URL {
        let url = try await UniqueItemNaming.workspace.create(in: directory, baseName: baseName, extension: "") { url throws(LiteMDError) in
            try await self.fileSystem.createDirectory(at: url)
        }
        await refreshDirectory(directory)
        return url
    }

    @discardableResult
    public func rename(_ url: URL, to proposedName: String) async throws(LiteMDError) -> URL {
        var name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidFileName(name) else {
            throw LiteMDError(kind: .workspace, reason: .invalidName, fileName: proposedName)
        }
        // 输入名称没有扩展名时，保留原 Markdown 扩展名。
        let isDirectory = await fileSystem.isDirectory(at: url)
        if !isDirectory, MarkdownFileType.isDocument(url), (name as NSString).pathExtension.isEmpty {
            name += "." + url.pathExtension
        }

        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        guard destination.path != url.path else { return url }
        try await workspaceOperation { () throws(LiteMDError) in try await fileSystem.moveItem(from: url, to: destination) }
        onItemMoved?(url, destination)
        await refreshDirectory(url.deletingLastPathComponent())
        invalidateFileIndex()
        return destination.standardizedFileURL
    }

    @discardableResult
    public func move(_ url: URL, into directory: URL) async throws(LiteMDError) -> URL {
        let source = url.standardizedFileURL
        let target = directory.standardizedFileURL
        guard target.path != source.path, !target.path.hasPrefix(source.path + "/") else {
            throw LiteMDError(kind: .workspace, reason: .invalidName, fileName: url.lastPathComponent)
        }
        guard source.deletingLastPathComponent().path != target.path else { return source }

        let destination = target.appendingPathComponent(source.lastPathComponent)
        try await workspaceOperation { () throws(LiteMDError) in try await fileSystem.moveItem(from: source, to: destination) }
        onItemMoved?(source, destination)
        await refreshDirectory(source.deletingLastPathComponent())
        await refreshDirectory(target)
        invalidateFileIndex()
        return destination.standardizedFileURL
    }

    @discardableResult
    public func duplicate(_ url: URL) async throws(LiteMDError) -> URL {
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent + " copy"
        let copy = try await UniqueItemNaming.workspace.create(in: directory, baseName: base, extension: url.pathExtension) { destination throws(LiteMDError) in
            try await self.fileSystem.copyItem(from: url, to: destination)
        }
        await refreshDirectory(directory)
        invalidateFileIndex()
        return copy
    }

    public func trash(_ url: URL) async throws(LiteMDError) {
        try await workspaceOperation { () throws(LiteMDError) in try await fileSystem.trashItem(at: url) }
        onItemTrashed?(url)
        await refreshDirectory(url.deletingLastPathComponent())
        invalidateFileIndex()
    }

    // MARK: Helpers

    /// 文件树操作失败时按 `.workspace` 报告（“文件夹操作未能完成”），而不是“无法打开某文件”。
    private func workspaceOperation(_ operation: () async throws(LiteMDError) -> Void) async throws(LiteMDError) {
        do {
            try await operation()
        } catch {
            throw error.with(kind: .workspace)
        }
    }

    static func isValidFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains(":") && name.utf8.count <= 255
    }
}
