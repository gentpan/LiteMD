import AppKit
import LiteMDApplication
import LiteMDBackup
import LiteMDConversion
import LiteMDDomain
import LiteMDEditor
import LiteMDInfrastructure
import LiteMDMarkdown
import Observation
import SwiftUI

/// SwiftUI 也定义了 `Document`，App 模块内统一指向 LiteMD 的编辑会话模型。
typealias Document = LiteMDApplication.Document

enum SidebarTab: String, CaseIterable, Identifiable {
    case files
    case outline
    case search

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .files: "Files"
        case .outline: "Outline"
        case .search: "Search"
        }
    }

    var symbol: String {
        switch self {
        case .files: "folder"
        case .outline: "list.bullet.indent"
        case .search: "magnifyingglass"
        }
    }
}

struct RenameRequest: Identifiable {
    let id = UUID()
    let url: URL
    var name: String
}

struct CompareRequest: Identifiable {
    let id = UUID()
    let document: Document
    let diskText: String
    let localText: String
}

/// 组合根：创建服务、连接事件、提供界面意图（spec §152–153）。
/// 视图只发出意图，不直接写文件。
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let settings = AppSettings()
    let documents: DocumentService
    let workspace: WorkspaceService
    let session: SessionService
    let assets: AssetService
    let searcher: WorkspaceSearcher
    let search = SearchModel()
    let backup: BackupModel
    let backlinks = BacklinksModel()
    let updates = UpdateModel()
    let folderAppearance: FolderAppearanceModel
    @ObservationIgnored let backlinkIndex: BacklinkIndex

    @ObservationIgnored let fileSystem: LocalFileSystem
    @ObservationIgnored let preview = PreviewController()
    /// 用户导入的字体（只注册到本进程）。
    let customFonts = CustomFontStore()
    @ObservationIgnored let conversion = DocumentConversion()
    @ObservationIgnored private let watcher = FSEventsWatcher()
    @ObservationIgnored private var editors: [DocumentID: EditorController] = [:]
    @ObservationIgnored private var sessionSaveTask: Task<Void, Never>?
    @ObservationIgnored private var editorSettingsTask: Task<Void, Never>?
    /// 启动流程（读会话、恢复上次打开的文件夹与文档）。只跑一次，其他调用方等它完成。
    @ObservationIgnored private var startTask: Task<Void, Never>?

    var sidebarTab: SidebarTab = .files
    var editorMode: EditorMode = .split {
        // 同步滚动只在分栏时跟随编辑区；在其他模式下滚动过，切回分栏时补一次，预览才不会停在旧位置。
        didSet {
            documents.rendersPreviewHTML = editorMode == .split
            if editorMode == .split, oldValue != .split { syncPreviewScroll() }
        }
    }
    var columnVisibility: NavigationSplitViewVisibility = .all
    var isQuickOpenPresented = false
    var isCommandPalettePresented = false
    var isRestorePresented = false
    var versionHistoryDocument: Document?
    var folderExportRequest: FolderExportRequest?
    /// 正在编辑图标与颜色的文件夹（侧栏中对应的行弹出面板）。
    var folderAppearancePickerURL: URL?
    /// 正在从 iCloud 下载的文件。
    private(set) var cloudDownloads: Set<URL> = []
    var settingsTab: SettingsTab = .general
    var renameRequest: RenameRequest?
    var compareRequest: CompareRequest?
    var pendingRecovery: [RecoveryEntry] = []

    /// 主窗口上已经有面板。同一视图同时只能弹出一个面板，第二个会被丢弃，
    /// 它的状态卡在 true，之后对应的快捷键就再也没反应。
    var isPresentingSheet: Bool {
        isQuickOpenPresented || isCommandPalettePresented || isRestorePresented
            || versionHistoryDocument != nil || compareRequest != nil || folderExportRequest != nil
    }

    /// 详情栏宽度，用于在标题栏中排布标签页。
    var detailColumnWidth: CGFloat = Layout.defaultWindowWidth - Layout.sidebarIdealWidth

    /// 退出获准后重新启动（切换语言后使用）。
    @ObservationIgnored var isRelaunchRequested = false

    /// 由主窗口注入，用于在窗口被关闭后重新打开。
    @ObservationIgnored var openMainWindow: (() -> Void)?
    /// 由主窗口注入（SwiftUI 的 openSettings 只能在视图中取得）。
    @ObservationIgnored var openSettingsWindow: (() -> Void)?

    private init() {
        Document.untitledTitle = { number in
            number > 1 ? String(localized: "Untitled \(number)") : String(localized: "Untitled")
        }
        let fileSystem = LocalFileSystem()
        let support = AppDirectories.applicationSupport()
        self.fileSystem = fileSystem
        documents = DocumentService(
            fileSystem: fileSystem,
            parser: MarkdownParser(fileURLPrefix: AssetSchemeHandler.fileURLPrefix),
            recoveryStore: FileRecoveryStore(directory: support.appendingPathComponent("Recovery", isDirectory: true)),
            versionHistory: FileVersionHistoryStore(directory: support.appendingPathComponent("History", isDirectory: true))
        )
        workspace = WorkspaceService(fileSystem: fileSystem)
        session = SessionService(store: JSONStateStore(directory: support.appendingPathComponent("State", isDirectory: true)))
        folderAppearance = FolderAppearanceModel(store: JSONStateStore(directory: support.appendingPathComponent("State", isDirectory: true)))
        assets = AssetService(fileSystem: fileSystem)
        searcher = WorkspaceSearcher(fileSystem: fileSystem)
        backup = BackupModel(settings: settings, directory: support.appendingPathComponent("Backup", isDirectory: true))
        backlinkIndex = BacklinkIndex(fileSystem: fileSystem)
        connect()
    }

    private func connect() {
        search.model = self
        backlinks.model = self
        documents.onDocumentsChanged = { [weak self] in self?.documentsDidChange() }
        documents.onFileOpened = { [weak self] url in self?.session.noteOpenedFile(url) }
        documents.onDocumentSaved = { [weak self] document in
            if let url = document.fileReference?.url { self?.backup.noteLocalChange(at: url) }
        }
        backup.workspaceRoot = { [weak self] in self?.workspace.rootURL }
        backup.ignoreRules = { [weak self] in self?.workspace.rules ?? WorkspaceIgnoreRules() }
        workspace.onItemMoved = { [weak self] old, new in
            self?.documents.itemMoved(from: old, to: new)
            self?.folderAppearance.itemMoved(from: old, to: new)
        }
        workspace.onItemTrashed = { [weak self] url in
            self?.documents.itemTrashed(at: url)
            self?.folderAppearance.itemRemoved(at: url)
        }
        watcher.eventHandler = { [weak self] events in self?.handleFileEvents(events) }
        settings.onChange = { [weak self] in self?.applySettings() }
        customFonts.loadInstalled()
        // 导入或删除字体后要刷新字体选择器、编辑区与预览。
        customFonts.onChange = { [weak self] in
            FontCatalog.invalidate()
            self?.applySettings()
        }
        // 外观模式为“跟随系统”时，系统切换明暗后换用对应主题。
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.settings.systemIsDark = SystemAppearance.isDark
            }
        }
        preview.onLinkActivated = { [weak self] url in self?.handlePreviewLink(url) }
        applySettings()
    }

    // MARK: Derived state

    var activeDocument: Document? { documents.activeDocument }

    var showsWelcome: Bool {
        workspace.root == nil && documents.documents.isEmpty
    }

    var windowTitle: String {
        activeDocument?.displayName ?? workspace.root?.name ?? "LiteMD"
    }

    private func syncPreviewScroll() {
        guard settings.previewSyncScroll, let document = activeDocument,
              let line = editors[document.id]?.topVisibleLine() else { return }
        preview.scroll(toLine: line)
    }

    func editor(for document: Document) -> EditorController {
        if let existing = editors[document.id] { return existing }
        let controller = EditorController(document: document, model: self)
        controller.onVisibleLineChange = { [weak self, weak document] line in
            guard let self, let document, self.editorMode == .split, self.settings.previewSyncScroll,
                  self.documents.activeDocumentID == document.id else { return }
            self.preview.scroll(toLine: line)
        }
        editors[document.id] = controller
        return controller
    }

    var activeEditor: EditorController? {
        activeDocument.map(editor(for:))
    }

    func previewBaseDirectory(for document: Document) -> URL {
        document.fileReference?.url.deletingLastPathComponent()
            ?? workspace.rootURL
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    // MARK: Lifecycle

    func start() async {
        if let startTask { return await startTask.value }
        let task = Task { await performStart() }
        startTask = task
        await task.value
    }

    private func performStart() async {
        await session.load()
        await folderAppearance.load()
        #if DEBUG
        FolderAppearanceDebugRender.renderIfRequested(model: self)
        #endif
        await restoreSession()
        #if DEBUG
        await FolderExportDebugRun.runIfRequested(model: self)
        #endif
        updates.checkOnLaunchIfNeeded()
        let entries = await documents.pendingRecoveryEntries()
        if !entries.isEmpty {
            pendingRecovery = entries
        }
    }

    /// 把“格式”里选的字体翻译成预览用的 CSS。导入的字体只注册到本进程，
    /// WKWebView 拿不到，所以还要把文件名带过去让预览自己 `@font-face`。
    private func previewFonts() -> PreviewTemplate.Fonts {
        var faces: [PreviewTemplate.Fonts.Face] = []

        func cssFamily(_ family: String, fallback: String) -> String? {
            switch family {
            case "": return nil
            case "serif": return #"ui-serif, Georgia, "Songti SC", serif"#
            case "mono": return #"ui-monospace, "SF Mono", Menlo, monospace"#
            default:
                if let imported = customFonts.font(forFamily: family),
                   !faces.contains(where: { $0.fileName == imported.fileName }) {
                    faces.append(.init(family: imported.familyName, fileName: imported.fileName))
                }
                let escaped = family.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(escaped)\", \(fallback)"
            }
        }

        let sansFallback = #"-apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans", sans-serif"#
        let monoFallback = #"ui-monospace, "SF Mono", Menlo, monospace"#

        let body = cssFamily(settings.textFont, fallback: sansFallback)
        // 标题留空表示“与正文相同”。
        let heading = settings.headingFont.isEmpty ? body : cssFamily(settings.headingFont, fallback: sansFallback)
        let code = cssFamily(settings.codeFontFamily, fallback: monoFallback)

        return PreviewTemplate.Fonts(body: body, heading: heading, code: code, faces: faces)
    }

    private func applySettings() {
        documents.isAutosaveEnabled = settings.autoSave
        documents.autosaveDelay = .milliseconds(settings.autoSaveDelayMilliseconds)
        settings.applyTheme()
        settings.applyAppIcon()
        let previewFonts = previewFonts()
        ThemeRuntime.shared.fonts = previewFonts
        preview.apply(theme: settings.activeTheme, fonts: previewFonts)
        if workspace.rules.showHiddenFiles != settings.showHiddenFiles {
            workspace.rules.showHiddenFiles = settings.showHiddenFiles
            Task { await workspace.refreshAll() }
        }
        // 拖动滑块会连续修改设置，编辑器排版合并到下一拍统一应用。
        editorSettingsTask?.cancel()
        editorSettingsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled, let self else { return }
            for editor in self.editors.values {
                editor.applySettings()
            }
        }
    }

    private func documentsDidChange() {
        let openIDs = Set(documents.documents.map(\.id))
        for (id, editor) in editors where !openIDs.contains(id) {
            editor.tearDown()
            editors[id] = nil
        }
        updateWatchedDirectories()
        scheduleSessionSave()
    }

    // MARK: File watching

    private func updateWatchedDirectories() {
        var directories = Set<URL>()
        if let root = workspace.rootURL {
            directories.insert(root)
        }
        for document in documents.documents {
            guard let url = document.fileReference?.url, !workspace.contains(url) else { continue }
            directories.insert(url.deletingLastPathComponent())
        }
        watcher.setWatchedDirectories(directories)
    }

    private func handleFileEvents(_ events: [FileEvent]) {
        // 忽略自身原子写入产生的临时文件。
        let relevant = events.filter { !($0.url.lastPathComponent.contains(".litemd-") && $0.url.pathExtension == "tmp") }
        guard !relevant.isEmpty else { return }
        for event in relevant {
            backup.noteLocalChange(at: event.url)
        }
        Task {
            await documents.handleFileEvents(relevant)
            await workspace.handleFileEvents(relevant)
            for event in relevant {
                await backlinkIndex.invalidate(event.url)
            }
            if relevant.contains(where: { MarkdownFileType.isDocument($0.url) }) {
                backlinks.refresh(for: activeDocument?.fileReference?.url)
            }
        }
    }

    // MARK: Session

    private func currentSessionState() -> SessionState {
        var expanded: [URL] = []
        if let root = workspace.root {
            var queue = root.children ?? []
            while !queue.isEmpty {
                let node = queue.removeFirst()
                guard node.isDirectory, node.isExpanded else { continue }
                expanded.append(node.url)
                queue.append(contentsOf: node.children ?? [])
            }
        }
        return SessionState(
            workspaceURL: workspace.rootURL,
            openDocumentURLs: documents.documents.compactMap { $0.fileReference?.url },
            activeDocumentURL: activeDocument?.fileReference?.url,
            editorMode: editorMode,
            sidebarTab: sidebarTab.rawValue,
            expandedFolderURLs: expanded
        )
    }

    func scheduleSessionSave() {
        sessionSaveTask?.cancel()
        sessionSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            await self.session.saveSession(self.currentSessionState())
        }
    }

    func saveSessionNow() async {
        sessionSaveTask?.cancel()
        await session.saveSession(currentSessionState())
    }

    private func restoreSession() async {
        guard settings.restoreSession, let state = await session.loadSession() else { return }
        editorMode = state.editorMode
        if let tab = state.sidebarTab.flatMap(SidebarTab.init(rawValue:)) {
            sidebarTab = tab
        }
        if let workspaceURL = state.workspaceURL, await fileSystem.isDirectory(at: workspaceURL) {
            try? await workspace.open(workspaceURL)
            backup.workspaceDidOpen()
            for url in state.expandedFolderURLs.sorted(by: { $0.path.count < $1.path.count }) {
                guard let node = workspace.node(for: url) else { continue }
                node.isExpanded = true
                try? await workspace.loadChildren(of: node)
            }
        }
        for url in state.openDocumentURLs where await fileSystem.itemExists(at: url) {
            _ = try? await documents.openDocument(at: url)
        }
        if let active = state.activeDocumentURL,
           let document = documents.documents.first(where: { $0.fileReference?.url == active.standardizedFileURL }) {
            documents.activeDocumentID = document.id
        }
        updateWatchedDirectories()
    }

    // MARK: Recovery

    func recoverDocuments() {
        let entries = pendingRecovery
        pendingRecovery = []
        Task {
            let failures = await documents.recover(entries)
            if let failure = failures.first {
                SystemIntegration.present(failure)
            }
        }
    }

    func discardRecovery() {
        pendingRecovery = []
        Task { await documents.discardRecoveryEntries() }
    }

    // MARK: Open

    func newDocument() {
        documents.newDocument()
    }

    func newDocument(text: String) {
        documents.newDocument(text: text)
    }

    func searchInFolder(_ query: String) {
        search.query = query
        showSidebar(.search)
    }

    func showOpenPanel() {
        let urls = SystemIntegration.chooseFiles()
        guard !urls.isEmpty else { return }
        Task { await open(urls) }
    }

    func showOpenFolderPanel() {
        guard let url = SystemIntegration.chooseFolder() else { return }
        Task { await openWorkspace(url) }
    }

    func open(_ urls: [URL]) async {
        // 冷启动时从访达打开文件会和会话恢复同时进行；先等会话恢复完，
        // 否则恢复出来的上次文件夹和文档会盖掉用户刚双击的文件。
        await start()
        for url in urls {
            if await fileSystem.isDirectory(at: url) {
                await openWorkspace(url)
            } else if !MarkdownFileType.isDocument(url), SystemImporters.canImport(url) {
                // Word、PDF 等其他格式：转换为 Markdown。
                await importFile(url)
            } else {
                await openDocument(url)
            }
        }
    }

    @discardableResult
    func openDocument(_ url: URL) async -> Document? {
        let standardized = url.standardizedFileURL
        let needsDownload = await fileSystem.cloudStatus(at: standardized).needsDownload
        if needsDownload { cloudDownloads.insert(standardized) }
        defer { cloudDownloads.remove(standardized) }
        do {
            return try await documents.openDocument(at: standardized)
        } catch {
            SystemIntegration.present(error)
            return nil
        }
    }

    func isDownloadingFromCloud(_ url: URL) -> Bool {
        cloudDownloads.contains(url.standardizedFileURL)
    }

    /// 打开 iCloud Drive 中的文件夹。
    func showOpeniCloudFolderPanel() {
        guard let iCloud = CloudLocation.iCloudDriveURL else {
            SystemIntegration.runAlert(
                title: String(localized: "iCloud Drive is not set up on this Mac."),
                message: String(localized: "Turn on iCloud Drive in System Settings → Apple Account → iCloud."),
                buttons: [String(localized: "OK")],
                style: .informational
            )
            return
        }
        guard let url = SystemIntegration.chooseFolder(startingAt: iCloud) else { return }
        Task { await openWorkspace(url) }
    }

    /// 当前文件夹是否在 iCloud Drive 中。
    var workspaceIsInCloud: Bool {
        workspace.rootURL.map(CloudLocation.isInCloudDrive) ?? false
    }

    /// 把当前文件夹移动到 iCloud Drive（用户确认后执行，移动后重新打开）。
    func moveWorkspaceToiCloudDrive() {
        guard let root = workspace.rootURL, let iCloud = CloudLocation.iCloudDriveURL else { return }
        let destination = iCloud.appendingPathComponent(root.lastPathComponent)
        let choice = SystemIntegration.runAlert(
            title: String(localized: "Move “\(root.lastPathComponent)” to iCloud Drive?"),
            message: String(localized: "The folder is moved to iCloud Drive and stays available on your other devices. Files are moved, not copied."),
            buttons: [String(localized: "Cancel"), String(localized: "Move")],
            style: .informational
        )
        guard choice == 1 else { return }
        Task {
            do {
                await documents.finishPendingSaves(under: root)
                try await fileSystem.moveItem(from: root, to: destination)
                // 和文件树里的移动一样善后：已打开的标签改指向新位置，文件夹的图标与颜色跟着走。
                documents.itemMoved(from: root, to: destination)
                folderAppearance.itemMoved(from: root, to: destination)
                await openWorkspace(destination)
            } catch {
                SystemIntegration.present(error)
            }
        }
    }

    func openWorkspace(_ url: URL) async {
        do {
            try await workspace.open(url)
            session.noteOpenedWorkspace(url)
            backup.workspaceDidOpen()
            sidebarTab = .files
            columnVisibility = .all
            search.reset()
            updateWatchedDirectories()
            scheduleSessionSave()
        } catch {
            SystemIntegration.present(error)
        }
    }

    func closeWorkspace() {
        workspace.close()
        backup.workspaceDidClose()
        search.reset()
        updateWatchedDirectories()
        scheduleSessionSave()
    }

    func openRecent(_ url: URL) {
        Task {
            guard await fileSystem.itemExists(at: url) else {
                session.removeRecent(url)
                SystemIntegration.present(LiteMDError(kind: .file, reason: .notFound, fileName: url.lastPathComponent))
                return
            }
            await open([url])
        }
    }

    // MARK: Save

    func saveActiveDocument() {
        guard let document = activeDocument else { return }
        Task { await save(document) }
    }

    func saveActiveDocumentAs() {
        guard let document = activeDocument else { return }
        Task { await saveAs(document) }
    }

    @discardableResult
    func save(_ document: Document) async -> Bool {
        if document.isUntitled {
            return await saveAs(document)
        }
        do {
            try await documents.save(document)
            return true
        } catch {
            // 冲突由编辑区横幅处理，其他错误弹出提示。
            if error.kind != .conflict {
                SystemIntegration.present(error)
            }
            return false
        }
    }

    @discardableResult
    func saveAs(_ document: Document) async -> Bool {
        let directory = document.fileReference?.url.deletingLastPathComponent() ?? workspace.rootURL
        let name = document.fileReference?.url.deletingPathExtension().lastPathComponent ?? suggestedFileName(for: document)
        guard let url = SystemIntegration.chooseSaveLocation(suggestedName: name, directory: directory) else { return false }
        do {
            try await documents.save(document, to: url)
            await workspace.refreshDirectory(url.deletingLastPathComponent())
            updateWatchedDirectories()
            return true
        } catch {
            SystemIntegration.present(error)
            return false
        }
    }

    private func suggestedFileName(for document: Document) -> String {
        if let heading = document.parseResult?.headings.first?.title {
            let name = AssetService.sanitizedBaseName(heading)
            if name != "image" { return name }
        }
        return "Untitled"
    }

    // MARK: Close

    /// ⌘W。菜单里的“关闭标签页”顶替了系统的“关闭”，所以设置窗口等其他窗口在前台时，
    /// 要关的是那个窗口，而不是主窗口里的当前标签。
    func closeActiveDocument() {
        let keyWindow = NSApp.keyWindow
        let mainWindowIsKey = keyWindow?.identifier?.rawValue.hasPrefix(MainWindowView.windowID) == true
        guard mainWindowIsKey, let document = activeDocument else {
            keyWindow?.performClose(nil)
            return
        }
        Task { await close(document) }
    }

    @discardableResult
    func close(_ document: Document) async -> Bool {
        if await documents.close(document) { return true }

        let choice = SystemIntegration.runAlert(
            title: String(localized: "Do you want to save the changes made to “\(document.displayName)”?"),
            message: String(localized: "Your changes will be lost if you don’t save them."),
            buttons: [String(localized: "Save"), String(localized: "Don’t Save"), String(localized: "Cancel")]
        )
        switch choice {
        case 0:
            guard await save(document) else { return false }
            return await documents.close(document)
        case 1:
            await documents.discardChangesAndClose(document)
            return true
        default:
            return false
        }
    }

    func closeOtherDocuments(except kept: Document) {
        Task {
            for document in documents.documents where document.id != kept.id {
                guard await close(document) else { break }
            }
        }
    }

    func closeDocumentsToTheRight(of anchor: Document) {
        guard let index = documents.documents.firstIndex(where: { $0.id == anchor.id }) else { return }
        let targets = Array(documents.documents[(index + 1)...])
        Task {
            for document in targets {
                guard await close(document) else { break }
            }
        }
    }

    func reopenClosedDocument() {
        Task {
            do {
                try await documents.reopenClosedDocument()
            } catch {
                SystemIntegration.present(error)
            }
        }
    }

    func selectDocument(offset: Int) {
        let list = documents.documents
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == documents.activeDocumentID } ?? 0
        let next = (index + offset + list.count) % list.count
        documents.activeDocumentID = list[next].id
    }

    // MARK: Termination

    /// 走正常退出流程（保存、确认未保存内容）；获准退出后由 AppDelegate 重新打开应用。
    func relaunch() {
        isRelaunchRequested = true
        // terminate 会开启嵌套事件循环，等待保存流程（主 actor 任务）完成。
        // 如果在 Swift 并发任务里直接调用，主 actor 被占用，保存任务永远无法执行；交给 RunLoop 在下一拍调用。
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }

    /// 退出前保存；仍有未保存内容时询问用户。返回是否允许退出。
    func prepareForTermination() async -> Bool {
        await saveSessionNow()
        var unsaved = await documents.prepareForTermination()
        guard !unsaved.isEmpty else { return true }

        let title = unsaved.count == 1
            ? String(localized: "“\(unsaved[0].displayName)” has unsaved changes.")
            : String(localized: "\(unsaved.count) documents have unsaved changes.")
        let choice = SystemIntegration.runAlert(
            title: title,
            message: String(localized: "Do you want to save the changes before quitting?"),
            buttons: [String(localized: "Save…"), String(localized: "Discard Changes"), String(localized: "Cancel")]
        )
        switch choice {
        case 0:
            for document in unsaved {
                documents.activeDocumentID = document.id
                guard await save(document) else { return false }
            }
            unsaved = await documents.prepareForTermination(saveEvenIfAutosaveDisabled: true)
            return unsaved.isEmpty
        case 1:
            await documents.discardAllForTermination()
            return true
        default:
            return false
        }
    }

    // MARK: Editing

    func perform(_ command: EditorCommand) {
        activeEditor?.perform(command)
    }

    func insertImageFromPanel() {
        guard let editor = activeEditor, let document = activeDocument else { return }
        // 图片要存到文档旁边：未保存的文档先提示，别等用户选完图片才说。
        guard document.fileReference != nil else {
            SystemIntegration.present(LiteMDError(kind: .asset, reason: .requiresSavedDocument, fileName: document.displayName))
            return
        }
        let urls = SystemIntegration.chooseImages()
        editor.importImages(files: urls)
    }

    func toggleEditorMode() {
        editorMode = editorMode == .split ? .source : .split
        scheduleSessionSave()
    }

    func setEditorMode(_ mode: EditorMode) {
        editorMode = mode
        scheduleSessionSave()
    }

    func showSidebar(_ tab: SidebarTab) {
        sidebarTab = tab
        columnVisibility = .all
    }

    // MARK: Import & export

    func importFromOtherFormats() {
        let urls = SystemIntegration.chooseImportFiles()
        guard !urls.isEmpty else { return }
        Task {
            for url in urls {
                await importFile(url)
            }
        }
    }

    /// 转换其他格式：选择保存位置 → 写入 Markdown 与提取的图片 → 打开。
    func importFile(_ source: URL) async {
        let suggestedName = source.deletingPathExtension().lastPathComponent
        let directory = workspace.rootURL ?? source.deletingLastPathComponent()
        guard let destination = SystemIntegration.chooseSaveLocation(suggestedName: suggestedName, directory: directory) else { return }

        let location = settings.assetLocation
        let assetDirectory = location.directory(forDocumentAt: destination)
        let relativeAssetDirectory = AssetService.relativePath(from: destination.deletingLastPathComponent(), to: assetDirectory)
        let prefix = AssetService.sanitizedBaseName(destination.deletingPathExtension().lastPathComponent)

        do {
            let result = try await conversion.importDocument(
                at: source,
                options: ImportOptions(assetDirectory: relativeAssetDirectory, assetPrefix: prefix)
            )
            var markdown = result.markdown
            for asset in result.assets {
                let written = try await assets.importNamedData(asset.data, fileName: asset.fileName, forDocumentAt: destination, location: location)
                let expected = relativeAssetDirectory.isEmpty ? asset.fileName : "\(relativeAssetDirectory)/\(asset.fileName)"
                if written.markdownPath != expected {
                    markdown = markdown.replacingOccurrences(of: "(\(expected))", with: "(\(written.markdownPath))")
                }
            }
            _ = try await fileSystem.writeText(markdown, encoding: .utf8, lineEnding: .lf, to: destination)
            await workspace.refreshDirectory(destination.deletingLastPathComponent())
            await openDocument(destination)
        } catch let error as ConversionError {
            let message: String = switch error {
            case .empty: String(localized: "No text could be found in this file. Scanned PDFs without a text layer cannot be converted.")
            case .unsupported: String(localized: "This file type is not supported.")
            case .corrupted, .missingPart: String(localized: "The file appears to be damaged or is not in the expected format.")
            }
            SystemIntegration.runAlert(
                title: String(localized: "Could not convert \(source.lastPathComponent)."),
                message: message,
                buttons: [String(localized: "OK")],
                details: error.details
            )
        } catch {
            SystemIntegration.present(error, title: String(localized: "Could not convert \(source.lastPathComponent)."))
        }
    }

    func export(_ format: ExportFormat) {
        guard let document = activeDocument else { return }
        let name = document.fileReference?.url.deletingPathExtension().lastPathComponent ?? document.displayName
        let directory = document.fileReference?.url.deletingLastPathComponent() ?? workspace.rootURL
        export(document.text, name: name, directory: directory, baseDirectory: previewBaseDirectory(for: document), format: format)
    }

    /// 从文件树导出：文件已经打开时用编辑器里的正文（包含未保存的修改），否则直接读磁盘。
    func export(_ url: URL, as format: ExportFormat) {
        let directory = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent
        Task {
            do {
                let markdown = try await markdownForExport(of: url)
                export(markdown, name: name, directory: directory, baseDirectory: directory, format: format)
            } catch {
                SystemIntegration.present(error)
            }
        }
    }

    private func export(_ markdown: String, name: String, directory: URL?, baseDirectory: URL, format: ExportFormat) {
        guard let destination = SystemIntegration.chooseExportLocation(suggestedName: name, format: format, directory: directory) else { return }
        Task {
            do {
                try await conversion.export(markdown: markdown, title: name, documentDirectory: baseDirectory, format: format, to: destination)
                SystemIntegration.revealInFinder(destination)
            } catch {
                SystemIntegration.runAlert(
                    title: String(localized: "Could not export \(destination.lastPathComponent)."),
                    message: String(localized: "An unexpected error occurred."),
                    buttons: [String(localized: "OK")],
                    details: String(describing: error)
                )
            }
        }
    }

    func printActiveDocument() {
        guard let document = activeDocument else { return }
        let markdown = document.text
        let name = document.displayName
        let baseDirectory = previewBaseDirectory(for: document)
        Task {
            do {
                try await conversion.print(markdown: markdown, title: name, documentDirectory: baseDirectory)
            } catch {
                SystemIntegration.present(error, title: String(localized: "Could not print “\(name)”."))
            }
        }
    }

    // MARK: Conflicts

    func reloadFromDisk(_ document: Document) {
        Task {
            do {
                try await documents.resolveConflictByReloading(document)
            } catch {
                SystemIntegration.present(error)
            }
        }
    }

    func keepLocalVersion(_ document: Document) {
        Task {
            do {
                try await documents.resolveConflictByKeepingLocal(document)
            } catch {
                SystemIntegration.present(error)
            }
        }
    }

    func compare(_ document: Document) {
        Task {
            do {
                let disk = try await documents.diskText(for: document)
                guard !isPresentingSheet else { return }
                compareRequest = CompareRequest(document: document, diskText: disk, localText: document.text)
            } catch {
                SystemIntegration.present(error)
            }
        }
    }

    // MARK: Navigation

    func revealHeading(_ heading: HeadingItem) {
        activeEditor?.moveCursor(to: heading.offset)
    }

    func openSearchResult(_ url: URL, match: SearchMatch) {
        Task {
            guard let document = await openDocument(url) else { return }
            editor(for: document).reveal(range: match.range)
        }
    }

    /// 把 Markdown 中的链接目标解析为本地文件（相对文档所在目录）。远程链接返回 nil。
    func resolveLocalURL(_ destination: String, relativeTo document: Document) -> URL? {
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: trimmed), let scheme = url.scheme, scheme.count > 1 {
            return url.isFileURL ? url.standardizedFileURL : nil
        }
        let path = String(trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        guard !path.isEmpty else { return nil }
        let decoded = path.removingPercentEncoding ?? path
        if decoded.hasPrefix("/") {
            return URL(fileURLWithPath: decoded).standardizedFileURL
        }
        if decoded.hasPrefix("~") {
            return URL(fileURLWithPath: (decoded as NSString).expandingTildeInPath).standardizedFileURL
        }
        return previewBaseDirectory(for: document).appendingPathComponent(decoded).standardizedFileURL
    }

    /// 编辑器右键“打开链接”：网页用浏览器，`.md` 在 LiteMD 中打开，`#锚点` 跳到对应标题。
    func openLinkDestination(_ destination: String, relativeTo document: Document) {
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            let anchor = String(trimmed.dropFirst()).removingPercentEncoding ?? String(trimmed.dropFirst())
            if let heading = document.parseResult?.headings.first(where: { $0.anchor == anchor }) {
                editor(for: document).moveCursor(to: heading.offset)
            }
            return
        }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "tel"].contains(scheme) {
            SystemIntegration.openExternally(url)
            return
        }
        guard let fileURL = resolveLocalURL(trimmed, relativeTo: document) else { return }
        Task {
            guard await fileSystem.itemExists(at: fileURL) else {
                SystemIntegration.present(LiteMDError(kind: .file, reason: .notFound, fileName: fileURL.lastPathComponent))
                return
            }
            if MarkdownFileType.isDocument(fileURL) {
                await openDocument(fileURL)
            } else {
                SystemIntegration.openLocalFile(fileURL)
            }
        }
    }

    func relativePath(for url: URL) -> String {
        guard let root = workspace.rootURL, workspace.contains(url), url.path != root.path else {
            return url.lastPathComponent
        }
        return String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    private func handlePreviewLink(_ url: URL) {
        if url.scheme == "litemd-wiki" {
            var raw = String(url.absoluteString.dropFirst("litemd-wiki:".count))
            if let hash = raw.firstIndex(of: "#") { raw = String(raw[..<hash]) }
            let target = raw.removingPercentEncoding ?? raw
            openWikiLink(target: target, anchor: url.fragment(percentEncoded: false), from: activeDocument)
            return
        }
        if let fileURL = AssetSchemeHandler.fileURL(from: url) {
            if MarkdownFileType.isDocument(fileURL) {
                Task { await openDocument(fileURL) }
            } else {
                Task {
                    if await fileSystem.itemExists(at: fileURL) {
                        SystemIntegration.openLocalFile(fileURL)
                    }
                }
            }
            return
        }
        if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "tel"].contains(scheme) {
            SystemIntegration.openExternally(url)
        }
    }

    // MARK: Workspace operations

    func createFile(in directory: URL) {
        Task {
            do {
                if let node = workspace.node(for: directory) { workspace.setExpanded(node, true) }
                let url = try await workspace.createMarkdownFile(in: directory)
                await openDocument(url)
                renameRequest = RenameRequest(url: url, name: url.lastPathComponent)
            } catch {
                SystemIntegration.present(error)
            }
        }
    }

    func createFolder(in directory: URL) {
        Task {
            do {
                if let node = workspace.node(for: directory) { workspace.setExpanded(node, true) }
                let url = try await workspace.createFolder(in: directory)
                renameRequest = RenameRequest(url: url, name: url.lastPathComponent)
            } catch {
                SystemIntegration.present(error)
            }
        }
    }

    func requestRename(_ url: URL) {
        renameRequest = RenameRequest(url: url, name: url.lastPathComponent)
    }

    func renameActiveDocument() {
        guard let url = activeDocument?.fileReference?.url else { return }
        requestRename(url)
    }

    func performRename(_ request: RenameRequest) {
        Task {
            do {
                await documents.finishPendingSaves(under: request.url)
                try await workspace.rename(request.url, to: request.name)
                updateWatchedDirectories()
            } catch {
                SystemIntegration.present(error)
            }
        }
    }

    func duplicate(_ url: URL) {
        Task {
            do {
                try await workspace.duplicate(url)
            } catch {
                SystemIntegration.present(error)
            }
        }
    }

    func move(_ url: URL, into directory: URL) {
        Task {
            do {
                await documents.finishPendingSaves(under: url)
                try await workspace.move(url, into: directory)
            } catch {
                SystemIntegration.present(error)
            }
        }
    }

    func moveToTrash(_ url: URL) {
        Task {
            do {
                await documents.finishPendingSaves(under: url)
                try await workspace.trash(url)
            } catch {
                SystemIntegration.present(error)
            }
        }
    }

    func trashActiveDocument() {
        guard let url = activeDocument?.fileReference?.url else { return }
        moveToTrash(url)
    }
}
