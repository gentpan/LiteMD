import Foundation
import LiteMDDomain
import Observation

/// Document 生命周期管理器（spec §108），同时维护打开文档的注册表（spec §109）。
@MainActor
@Observable
public final class DocumentService {
    /// 标签页顺序。
    public private(set) var documents: [Document] = []
    public var activeDocumentID: DocumentID? {
        didSet { if activeDocumentID != oldValue { renderPreviewIfNeeded() } }
    }

    @ObservationIgnored private let fileSystem: any FileSystem
    @ObservationIgnored private let recoveryStore: any RecoveryStoring
    @ObservationIgnored private let versionHistory: (any VersionHistoryStoring)?
    @ObservationIgnored let saveCoordinator: SaveCoordinator
    @ObservationIgnored let autosave: AutosaveCoordinator
    @ObservationIgnored let parseCoordinator: ParseCoordinator
    @ObservationIgnored let recovery: RecoveryCoordinator
    @ObservationIgnored private var recentlyClosed: [URL] = []

    /// 打开、关闭、移动文档后回调（更新 File Watcher、Session 等）。
    @ObservationIgnored public var onDocumentsChanged: (() -> Void)?
    /// 从磁盘打开文件后回调（更新 Recent）。
    @ObservationIgnored public var onFileOpened: ((URL) -> Void)?
    /// 文档成功写入磁盘后回调（触发自动备份等）。
    @ObservationIgnored public var onDocumentSaved: ((Document) -> Void)?

    public init(
        fileSystem: any FileSystem,
        parser: any MarkdownParsing,
        recoveryStore: any RecoveryStoring,
        versionHistory: (any VersionHistoryStoring)? = nil,
        historySnapshotInterval: TimeInterval = 600
    ) {
        self.fileSystem = fileSystem
        self.recoveryStore = recoveryStore
        self.versionHistory = versionHistory
        let saveCoordinator = SaveCoordinator(fileSystem: fileSystem, history: versionHistory, snapshotInterval: historySnapshotInterval)
        self.saveCoordinator = saveCoordinator
        self.autosave = AutosaveCoordinator(saveCoordinator: saveCoordinator)
        self.parseCoordinator = ParseCoordinator(parser: parser)
        self.recovery = RecoveryCoordinator(store: recoveryStore)

        saveCoordinator.didSave = { [weak self] document in
            self?.recovery.documentSaved(document)
            self?.onDocumentSaved?(document)
        }
    }

    // MARK: Configuration

    public var isAutosaveEnabled: Bool {
        get { autosave.isEnabled }
        set { autosave.isEnabled = newValue }
    }

    public var autosaveDelay: Duration {
        get { autosave.delay }
        set { autosave.delay = newValue }
    }

    /// 当前是否显示预览。不显示时解析只产出大纲与统计，不生成 HTML：
    /// 源码与实时预览模式下，每次改动都能省掉整篇渲染。
    public var rendersPreviewHTML: Bool {
        get { parseCoordinator.rendersHTML }
        set {
            guard newValue != parseCoordinator.rendersHTML else { return }
            parseCoordinator.rendersHTML = newValue
            renderPreviewIfNeeded()
        }
    }

    /// 需要预览、而当前文档的解析结果里没有 HTML（在不显示预览时解析的）时，立即补一次。
    private func renderPreviewIfNeeded() {
        guard parseCoordinator.rendersHTML, let document = activeDocument,
              document.parseResult?.includesHTML == false else { return }
        parseCoordinator.schedule(document, immediately: true)
    }

    public var recoveryInterval: Duration {
        get { recovery.interval }
        set { recovery.interval = newValue }
    }

    public var activeDocument: Document? {
        guard let activeDocumentID else { return nil }
        return document(with: activeDocumentID)
    }

    public func document(with id: DocumentID) -> Document? {
        documents.first { $0.id == id }
    }

    public func isSaving(_ document: Document) -> Bool {
        saveCoordinator.isSaving(document)
    }

    // MARK: Open / New

    @discardableResult
    public func newDocument(text: String = "") -> Document {
        let used = Set(documents.compactMap(\.untitledNumber))
        let number = (1...).first { !used.contains($0) } ?? 1
        let document = Document(fileReference: nil, text: "", untitledNumber: number)
        if !text.isEmpty {
            document.replaceAllText(text)
        }
        register(document)
        return document
    }

    /// 已打开时聚焦现有文档，不创建第二个 Buffer（spec §110）。
    @discardableResult
    public func openDocument(at url: URL) async throws(LiteMDError) -> Document {
        let url = url.standardizedFileURL
        if let existing = await existingDocument(for: url) {
            activeDocumentID = existing.id
            return existing
        }

        // iCloud 中尚未下载的文件先取回本地。
        try await fileSystem.ensureDownloaded(at: url)
        let loaded = try await fileSystem.readText(at: url)

        // 读取期间可能已被另一次调用打开。
        if let existing = existingDocument(for: url, identity: loaded.identity) {
            activeDocumentID = existing.id
            return existing
        }

        let reference = FileReference(url: url, encoding: loaded.encoding, lineEnding: loaded.lineEnding, identity: loaded.identity)
        let document = Document(fileReference: reference, text: loaded.text)
        document.knownDiskRevision = loaded.diskRevision
        register(document)
        onFileOpened?(url)
        return document
    }

    private func existingDocument(for url: URL) async -> Document? {
        // 路径相同时不必查询 inode。
        if let match = existingDocument(for: url, identity: nil) { return match }
        return existingDocument(for: url, identity: await fileSystem.identity(at: url))
    }

    private func existingDocument(for url: URL, identity: FileIdentity?) -> Document? {
        if let match = documents.first(where: { $0.fileReference?.url.standardizedFileURL == url }) {
            return match
        }
        guard let identity else { return nil }
        return documents.first { $0.fileReference?.identity == identity }
    }

    private func register(_ document: Document) {
        if let activeDocumentID, let index = documents.firstIndex(where: { $0.id == activeDocumentID }) {
            documents.insert(document, at: index + 1)
        } else {
            documents.append(document)
        }
        activeDocumentID = document.id
        parseCoordinator.schedule(document, immediately: true)
        onDocumentsChanged?()
    }

    // MARK: Editing

    /// 编辑器在每次文本变化完成后调用。IME 组合期间只记录状态，不触发 Parse / Autosave。
    public func noteTextDidChange(_ document: Document, isComposing: Bool) {
        document.isComposing = isComposing
        guard !isComposing else { return }
        autosave.documentDidChange(document)
        parseCoordinator.schedule(document)
        recovery.documentDidChange(document)
    }

    public func moveDocument(_ id: DocumentID, toIndex destination: Int) {
        guard let source = documents.firstIndex(where: { $0.id == id }) else { return }
        let document = documents.remove(at: source)
        let clamped = max(0, min(destination, documents.count))
        documents.insert(document, at: clamped)
        onDocumentsChanged?()
    }

    // MARK: Save

    public func save(_ document: Document) async throws(LiteMDError) {
        autosave.cancel(document)
        try await saveCoordinator.save(document, policy: .ifDirty)
    }

    /// Save As 与 Untitled 的首次保存。用户已在文件面板中确认覆盖。
    ///
    /// 目标文件已在另一个标签页中打开时拒绝保存（`.alreadyOpen`），不关闭也不合并那个标签页：
    /// 同一文件只能有一个 Buffer（spec §110），而那个标签页可能还有未保存的修改。
    public func save(_ document: Document, to url: URL) async throws(LiteMDError) {
        let url = url.standardizedFileURL
        if let other = await existingDocument(for: url), other !== document {
            throw LiteMDError(kind: .save, reason: .alreadyOpen, fileName: url.lastPathComponent)
        }

        await saveCoordinator.waitUntilIdle(document)
        autosave.cancel(document)

        let previousReference = document.fileReference
        let previousDiskRevision = document.knownDiskRevision
        let previousConflict = document.conflict

        document.setFileReference(FileReference(
            url: url,
            encoding: previousReference?.encoding ?? .utf8,
            lineEnding: previousReference?.lineEnding ?? .lf
        ))
        document.knownDiskRevision = nil
        document.conflict = .none

        do throws(LiteMDError) {
            try await saveCoordinator.save(document, policy: .always)
        } catch {
            document.setFileReference(previousReference)
            document.knownDiskRevision = previousDiskRevision
            document.conflict = previousConflict
            throw error
        }

        var reference = document.fileReference
        reference?.identity = await fileSystem.identity(at: url)
        document.setFileReference(reference)
        parseCoordinator.schedule(document, immediately: true)
        onFileOpened?(url)
        onDocumentsChanged?()
    }

    // MARK: Close

    /// 尝试关闭。开启 Autosave 时先保存；仍有未保存内容时返回 false，由界面询问用户。
    public func close(_ document: Document) async -> Bool {
        if document.isDirty, isAutosaveEnabled, document.fileReference != nil, !document.conflict.isConflict {
            autosave.cancel(document)
            try? await saveCoordinator.save(document, policy: .ifDirty)
        }
        await saveCoordinator.waitUntilIdle(document)
        guard !document.isDirty else { return false }
        finishClosing(document)
        return true
    }

    /// 用户确认放弃修改后关闭。
    public func discardChangesAndClose(_ document: Document) async {
        await saveCoordinator.waitUntilIdle(document)
        finishClosing(document)
    }

    private func finishClosing(_ document: Document) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        autosave.cancel(document)
        parseCoordinator.cancel(document)
        recovery.documentClosed(document)
        document.lifecycle = .closed

        if let url = document.fileReference?.url {
            recentlyClosed.removeAll { $0 == url }
            recentlyClosed.append(url)
            if recentlyClosed.count > 20 { recentlyClosed.removeFirst() }
        }

        documents.remove(at: index)
        if activeDocumentID == document.id {
            let neighbor = documents.indices.contains(index) ? index : documents.count - 1
            activeDocumentID = neighbor >= 0 ? documents[neighbor].id : nil
        }
        onDocumentsChanged?()
    }

    public var canReopenClosedDocument: Bool { !recentlyClosed.isEmpty }

    @discardableResult
    public func reopenClosedDocument() async throws(LiteMDError) -> Document? {
        while let url = recentlyClosed.popLast() {
            if await fileSystem.itemExists(at: url) {
                return try await openDocument(at: url)
            }
        }
        return nil
    }

    // MARK: Conflicts

    /// 冲突：用户选择“重新载入”。编辑器中的替换可以撤销。
    public func resolveConflictByReloading(_ document: Document) async throws(LiteMDError) {
        try await reloadFromDisk(document, expectedRevision: nil)
    }

    /// 冲突：用户选择“保留我的版本”，覆盖磁盘文件（若已删除则重新创建）。
    public func resolveConflictByKeepingLocal(_ document: Document) async throws(LiteMDError) {
        autosave.cancel(document)
        try await saveCoordinator.save(document, policy: .overwriteExternalChanges)
    }

    // MARK: Replace in folder

    /// 在没有打开的文件里替换文字：先把当前版本存入历史（可以在“历史版本”里找回），
    /// 再按原来的编码与换行符写回。已在标签页中打开的文件要通过编辑器替换（可以撤销），这里拒绝处理。
    /// 返回替换次数；没有匹配时不写文件。
    public func replaceText(inFileAt url: URL, _ query: SearchQuery, with replacement: String) async throws(LiteMDError) -> Int {
        let url = url.standardizedFileURL
        if await existingDocument(for: url) != nil {
            throw LiteMDError(kind: .save, reason: .alreadyOpen, fileName: url.lastPathComponent)
        }
        let loaded = try await fileSystem.readText(at: url)
        let result = WorkspaceSearcher.replacing(query, with: replacement, in: loaded.text)
        guard result.count > 0 else { return 0 }

        await saveCoordinator.waitForHistoryMigration()
        if let versionHistory, let data = try? await fileSystem.readData(at: url) {
            await versionHistory.storeSnapshot(of: url, data: data, date: Date())
        }
        _ = try await fileSystem.writeText(result.text, encoding: loaded.encoding, lineEnding: loaded.lineEnding, to: url, requireExisting: true)
        return result.count
    }

    // MARK: Version history

    /// 文档的历史版本与 iCloud 冲突版本（新到旧）。未保存过的文档没有历史。
    public func versionSnapshots(for document: Document) async -> [VersionSnapshot] {
        guard let url = document.fileReference?.url else { return [] }
        await saveCoordinator.waitForHistoryMigration()
        let history = await versionHistory?.snapshots(for: url) ?? []
        let conflicts = await fileSystem.cloudConflicts(at: url)
        return (history + conflicts).sorted { $0.date > $1.date }
    }

    /// 保留当前内容，清除 iCloud 的其他冲突版本。
    public func resolveCloudConflicts(for document: Document) async {
        guard let url = document.fileReference?.url else { return }
        await fileSystem.resolveCloudConflicts(at: url)
    }

    /// 立即把磁盘上的当前版本存为历史版本（恢复旧版本前调用，保证恢复可以反悔）。
    public func storeSnapshotOfDiskVersion(_ document: Document) async {
        await saveCoordinator.waitForHistoryMigration()
        guard let versionHistory, let url = document.fileReference?.url,
              let data = try? await fileSystem.readData(at: url) else { return }
        await versionHistory.storeSnapshot(of: url, data: data, date: Date())
    }

    /// 读取历史版本内容（按原文件的编码规则解码，换行统一为 LF）。
    public func text(of snapshot: VersionSnapshot) async throws(LiteMDError) -> String {
        try await fileSystem.readText(at: snapshot.fileURL).text
    }

    /// 冲突：用于对比的磁盘内容。
    public func diskText(for document: Document) async throws(LiteMDError) -> String {
        guard let reference = document.fileReference else {
            throw LiteMDError(kind: .file, reason: .notFound, fileName: document.displayName)
        }
        return try await fileSystem.readText(at: reference.url).text
    }

    /// - Parameter expectedRevision: 非 nil 时，只有读取完成后文档仍是该 revision 才替换内容，
    ///   否则说明用户在此期间继续编辑，转为冲突，绝不丢弃输入。
    private func reloadFromDisk(_ document: Document, expectedRevision: Int?) async throws(LiteMDError) {
        guard let reference = document.fileReference else { return }
        await saveCoordinator.waitUntilIdle(document)
        autosave.cancel(document)

        let loaded = try await fileSystem.readText(at: reference.url)

        if let expectedRevision, document.revision != expectedRevision || document.isDirty {
            document.conflict = .externalModified
            return
        }
        guard document.fileReference?.url == reference.url else { return }

        replaceText(of: document, with: loaded.text)
        var updated = reference
        updated.encoding = loaded.encoding
        updated.lineEnding = loaded.lineEnding
        updated.identity = loaded.identity
        document.setFileReference(updated)
        document.savedRevision = document.revision
        document.knownDiskRevision = loaded.diskRevision
        document.conflict = .none
        document.saveActivity = .idle
        recovery.documentClosed(document)
        parseCoordinator.schedule(document, immediately: true)
    }

    /// 整体替换正文：有编辑器时走编辑器（可撤销、选区合理），否则直接替换 Buffer。
    private func replaceText(of document: Document, with text: String) {
        guard text != document.buffer.snapshot() else { return }
        if let editor = document.textEditor {
            editor.replaceEntireText(with: text)
        } else {
            document.replaceAllText(text)
        }
    }

    // MARK: External changes

    /// File Watcher 事件入口（spec §121、§170）。
    public func handleFileEvents(_ events: [FileEvent]) async {
        guard !events.isEmpty else { return }
        for document in documents {
            guard let reference = document.fileReference else { continue }
            let path = reference.url.path
            let isRelevant = events.contains { event in
                let eventPath = event.url.standardizedFileURL.path
                return eventPath == path
                    || path.hasPrefix(eventPath + "/")
                    || event.flags.contains(.mustRescan)
            }
            if isRelevant {
                await refreshDiskState(document, events: events)
            }
        }
    }

    /// 检查文档对应的磁盘文件状态：自动跟随重命名、自动重新载入干净文档、脏文档进入冲突。
    public func refreshDiskState(_ document: Document, events: [FileEvent] = []) async {
        guard document.lifecycle == .ready,
              let reference = document.fileReference,
              let known = document.knownDiskRevision,
              !saveCoordinator.isSaving(document) else { return }
        let revisionAtStart = document.revision

        let current: DiskRevision?
        do {
            current = try await fileSystem.diskRevision(at: reference.url, includeHash: false)
        } catch {
            return
        }

        guard let current else {
            if let newURL = await locateMovedFile(reference, events: events) {
                saveCoordinator.itemMoved(from: reference.url, to: newURL)
                followMove(document, to: newURL)
                return
            }
            if document.conflict != .externalDeleted {
                document.conflict = .externalDeleted
                autosave.cancel(document)
            }
            return
        }

        if current.matchesMetadata(known) {
            if document.conflict == .externalDeleted { document.conflict = .none }
            return
        }

        guard let hashed = try? await fileSystem.diskRevision(at: reference.url, includeHash: true) else { return }
        if hashed.matchesContent(known) == true {
            document.knownDiskRevision = hashed
            if document.conflict == .externalDeleted { document.conflict = .none }
            return
        }

        if document.isDirty || document.revision != revisionAtStart || saveCoordinator.isSaving(document) {
            document.conflict = .externalModified
            autosave.cancel(document)
        } else {
            try? await reloadFromDisk(document, expectedRevision: revisionAtStart)
        }
    }

    private func locateMovedFile(_ reference: FileReference, events: [FileEvent]) async -> URL? {
        let path = reference.url.path
        let renamed = events.filter { $0.flags.contains(.renamed) }

        // 1. 文件本身被重命名：事件中存在同 inode 的新路径。
        if let inode = reference.identity?.inode {
            for event in renamed where event.inode == inode && event.url.path != path {
                if await fileSystem.identity(at: event.url) == reference.identity {
                    return event.url.standardizedFileURL
                }
            }
        }

        // 2. 上级目录被重命名：用目录事件的 inode 配对旧路径与新路径。
        for old in renamed {
            let oldPath = old.url.standardizedFileURL.path
            guard path.hasPrefix(oldPath + "/"), let inode = old.inode else { continue }
            let suffix = String(path.dropFirst(oldPath.count + 1))
            for new in renamed where new.inode == inode && new.url.path != old.url.path {
                let candidate = new.url.appendingPathComponent(suffix).standardizedFileURL
                if await fileSystem.identity(at: candidate) == reference.identity {
                    return candidate
                }
            }
        }
        return nil
    }

    private func followMove(_ document: Document, to url: URL) {
        guard var reference = document.fileReference else { return }
        reference.url = url
        document.setFileReference(reference)
        // 文件找到了，“已删除”不再成立；但外部修改造成的冲突仍需用户处理。
        if document.conflict == .externalDeleted { document.conflict = .none }
        // 移动期间失败或跳过的自动保存改为写入新位置。
        if document.isDirty { autosave.documentDidChange(document) }
        parseCoordinator.schedule(document, immediately: true)
        onDocumentsChanged?()
    }

    /// 重命名、移动文件或文件夹，或把它们移到废纸篓之前调用：立即执行等待中的自动保存，
    /// 并等待进行中的保存完成。否则保存会写回旧路径，把已经移走或删除的文件重新创建出来。
    public func finishPendingSaves(under url: URL) async {
        let path = url.standardizedFileURL.path
        let affected = documents.filter { document in
            guard let documentPath = document.fileReference?.url.path else { return false }
            return documentPath == path || documentPath.hasPrefix(path + "/")
        }
        for document in affected {
            // 与自动保存的条件一致：IME 组合中的内容不写入，跟随移动后再保存到新位置。
            if isAutosaveEnabled, document.isDirty, !document.isComposing, !document.conflict.isConflict {
                autosave.cancel(document)
                try? await saveCoordinator.save(document, policy: .ifDirty)
            }
            await saveCoordinator.waitUntilIdle(document)
        }
    }

    /// 应用内重命名 / 移动文件或文件夹后调用，更新受影响的文档路径与历史版本。
    public func itemMoved(from oldURL: URL, to newURL: URL) {
        saveCoordinator.itemMoved(from: oldURL, to: newURL)
        let oldPath = oldURL.standardizedFileURL.path
        for document in documents {
            guard let reference = document.fileReference else { continue }
            let path = reference.url.path
            if path == oldPath {
                followMove(document, to: newURL.standardizedFileURL)
            } else if path.hasPrefix(oldPath + "/") {
                let suffix = String(path.dropFirst(oldPath.count + 1))
                followMove(document, to: newURL.appendingPathComponent(suffix).standardizedFileURL)
            }
        }
    }

    /// 应用内把文件或文件夹移到废纸篓后调用：干净文档直接关闭，脏文档标记为已删除。
    public func itemTrashed(at url: URL) {
        let trashedPath = url.standardizedFileURL.path
        for document in documents {
            guard let path = document.fileReference?.url.path else { continue }
            guard path == trashedPath || path.hasPrefix(trashedPath + "/") else { continue }
            if document.isDirty {
                document.conflict = .externalDeleted
                autosave.cancel(document)
            } else {
                finishClosing(document)
            }
        }
    }

    // MARK: Recovery

    public func pendingRecoveryEntries() async -> [RecoveryEntry] {
        await recoveryStore.entries()
    }

    /// 恢复崩溃前未保存的文档。恢复后的文档为 Dirty，并立即写入新的 Recovery 快照。
    public func recover(_ entries: [RecoveryEntry]) async -> [LiteMDError] {
        var failures: [LiteMDError] = []
        for entry in entries {
            do throws(LiteMDError) {
                let content = try await recoveryStore.content(for: entry.documentID)
                let document: Document

                if let url = entry.originalURL, await fileSystem.itemExists(at: url) {
                    document = try await openDocument(at: url)
                    if content != document.buffer.snapshot() {
                        replaceText(of: document, with: content)
                        // 还原崩溃前对磁盘文件的认知：若之后磁盘被其他程序修改，保存时会进入冲突；
                        // 编码与换行符沿用编辑时的设置，不被外部改写后的文件带偏。
                        if let known = entry.knownDiskRevision {
                            document.knownDiskRevision = known
                        }
                        if var reference = document.fileReference {
                            reference.encoding = entry.encoding
                            reference.lineEnding = entry.lineEnding
                            document.setFileReference(reference)
                        }
                    }
                } else {
                    document = newDocument(text: content)
                }

                recovery.snapshot(document)
                recovery.remove(entry.documentID)
                noteTextDidChange(document, isComposing: false)
            } catch {
                failures.append(error)
            }
        }
        return failures
    }

    public func discardRecoveryEntries() async {
        await recoveryStore.removeAll()
    }

    // MARK: Termination

    /// 退出前立即保存所有可保存的文档，返回仍有未保存内容的文档。
    public func prepareForTermination(saveEvenIfAutosaveDisabled: Bool = false) async -> [Document] {
        for document in documents where document.isDirty && document.fileReference != nil && !document.conflict.isConflict {
            guard isAutosaveEnabled || saveEvenIfAutosaveDisabled else { continue }
            autosave.cancel(document)
            try? await saveCoordinator.save(document, policy: .ifDirty)
        }
        for document in documents {
            await saveCoordinator.waitUntilIdle(document)
        }
        await recovery.waitForPendingWrites()
        return documents.filter(\.isDirty)
    }

    /// 用户确认放弃全部未保存内容后，清理 Recovery，保证下次启动不再提示。
    public func discardAllForTermination() async {
        for document in documents {
            recovery.documentClosed(document)
        }
        await recovery.waitForPendingWrites()
    }
}
