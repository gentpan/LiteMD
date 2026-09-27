import Foundation
@testable import LiteMDApplication
import LiteMDDomain
import LiteMDInfrastructure
import Testing

@Suite("Document revision model")
@MainActor
struct DocumentRevisionTests {
    /// spec §178
    @Test func editingMakesDocumentDirty() async throws {
        let env = TestEnvironment()
        let url = env.directory.file("a.md", "hello")
        let document = try await env.service.openDocument(at: url)

        #expect(document.revision == document.savedRevision)
        #expect(!document.isDirty)

        document.type(" world")
        #expect(document.revision == document.savedRevision + 1)
        #expect(document.isDirty)
        #expect(document.saveState == .dirty)

        try await env.service.save(document)
        #expect(!document.isDirty)
        #expect(env.directory.read(url) == "hello world")
    }

    @Test func previewHTMLIsOnlyRenderedWhilePreviewIsShown() async throws {
        let env = TestEnvironment()
        env.service.rendersPreviewHTML = false
        let url = env.directory.file("a.md", "# Title\n\nBody")
        let document = try await env.service.openDocument(at: url)
        #expect(await waitUntil { document.parseResult != nil })
        #expect(document.parseResult?.includesHTML == false)
        #expect(document.parseResult?.headings.map(\.title) == ["Title"])

        // 切到分栏预览：当前文档立即补一次带 HTML 的解析。
        env.service.rendersPreviewHTML = true
        #expect(await waitUntil { document.parseResult?.includesHTML == true })
        #expect(document.parseResult?.html.contains("<h1") == true)
    }

    @Test func openingSameFileTwiceFocusesExistingDocument() async throws {
        let env = TestEnvironment()
        let url = env.directory.file("a.md", "x")
        let link = env.directory.url.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)

        let first = try await env.service.openDocument(at: url)
        _ = env.service.newDocument()
        let second = try await env.service.openDocument(at: url)
        let viaLink = try await env.service.openDocument(at: link)

        #expect(first === second)
        #expect(first === viaLink)
        #expect(env.service.documents.count == 2)
        #expect(env.service.activeDocumentID == first.id)
    }

    @Test func untitledDocumentsAreNumberedAndSavedAs() async throws {
        let env = TestEnvironment()
        let first = env.service.newDocument()
        let second = env.service.newDocument(text: "draft")
        #expect(first.displayName == "Untitled")
        #expect(second.displayName == "Untitled 2")
        #expect(second.isDirty)

        await #expect(throws: LiteMDError.self) {
            try await env.service.save(second)
        }

        let url = env.directory.file("draft.md")
        try await env.service.save(second, to: url)
        #expect(!second.isDirty)
        #expect(second.fileReference?.url == url)
        #expect(env.directory.read(url) == "draft")
    }
}

@Suite("SaveCoordinator")
@MainActor
struct SaveCoordinatorTests {
    /// spec §179：保存期间继续输入，不能错误地变为 clean。
    @Test func editDuringSaveKeepsDocumentDirty() async throws {
        let env = TestEnvironment()
        let url = env.directory.file("a.md", "v0")
        let document = try await env.service.openDocument(at: url)

        document.type("-10")
        let savingRevision = document.revision
        env.fileSystem.holdWrites()

        let saveTask = Task { try await env.service.save(document) }
        #expect(await waitUntil { env.fileSystem.writeCount == 1 })
        #expect(document.saveState == .saving)

        document.type("-11")
        env.fileSystem.releaseWrites()
        try await saveTask.value

        #expect(document.savedRevision == savingRevision)
        #expect(document.revision == savingRevision + 1)
        #expect(document.isDirty)
        #expect(env.directory.read(url) == "v0-10")
    }

    /// spec §101：同一文档不并发写入，等待中的保存合并为最新 revision。
    @Test func concurrentSavesAreCoalesced() async throws {
        let env = TestEnvironment()
        let url = env.directory.file("a.md", "")
        let document = try await env.service.openDocument(at: url)

        document.type("20")
        env.fileSystem.holdWrites()
        let first = Task { try await env.service.save(document) }
        #expect(await waitUntil { env.fileSystem.writeCount == 1 })

        document.type("-21")
        let second = Task { try await env.service.save(document) }
        document.type("-22")
        let third = Task { try await env.service.save(document) }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(env.fileSystem.writeCount == 1)

        env.fileSystem.releaseWrites()
        try await first.value
        try await second.value
        try await third.value

        #expect(env.fileSystem.writtenTexts == ["20", "20-21-22"])
        #expect(!document.isDirty)
        #expect(env.directory.read(url) == "20-21-22")
    }

    /// spec §180：外部修改后自动保存必须进入冲突，而不是覆盖。
    @Test func externalModificationBecomesConflict() async throws {
        let env = TestEnvironment(autosave: true)
        let url = env.directory.file("README.md", "Revision A")
        let document = try await env.service.openDocument(at: url)

        try externalWrite("Revision B", to: url)
        document.type(" + mine")
        env.service.noteTextDidChange(document, isComposing: false)

        #expect(await waitUntil { document.conflict == .externalModified })
        #expect(env.directory.read(url) == "Revision B")
        #expect(document.isDirty)
        #expect(env.fileSystem.writeCount == 0)

        // 冲突期间的手动保存同样不能覆盖。
        await #expect(throws: LiteMDError.self) {
            try await env.service.save(document)
        }
        #expect(env.directory.read(url) == "Revision B")
    }

    @Test func keepMineOverwritesAfterExplicitChoice() async throws {
        let env = TestEnvironment()
        let url = env.directory.file("a.md", "A")
        let document = try await env.service.openDocument(at: url)
        try externalWrite("B", to: url)
        document.type("-mine")

        await #expect(throws: LiteMDError.self) { try await env.service.save(document) }
        #expect(document.conflict == .externalModified)

        try await env.service.resolveConflictByKeepingLocal(document)
        #expect(document.conflict == .none)
        #expect(!document.isDirty)
        #expect(env.directory.read(url) == "A-mine")
    }

    @Test func reloadReplacesLocalContent() async throws {
        let env = TestEnvironment()
        let url = env.directory.file("a.md", "A")
        let document = try await env.service.openDocument(at: url)
        try externalWrite("B\r\nfrom disk", to: url)
        document.type("-mine")
        await #expect(throws: LiteMDError.self) { try await env.service.save(document) }

        #expect(try await env.service.diskText(for: document) == "B\nfrom disk")
        try await env.service.resolveConflictByReloading(document)
        #expect(document.text == "B\nfrom disk")
        #expect(document.fileReference?.lineEnding == .crlf)
        #expect(!document.isDirty)
        #expect(document.conflict == .none)
    }

    @Test func metadataOnlyChangeIsNotAConflict() async throws {
        let env = TestEnvironment()
        let url = env.directory.file("a.md", "same")
        let document = try await env.service.openDocument(at: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)

        document.type("!")
        try await env.service.save(document)
        #expect(env.directory.read(url) == "same!")
    }

    @Test func deletedFileBecomesConflictAndCanBeRecreated() async throws {
        let env = TestEnvironment()
        let url = env.directory.file("a.md", "A")
        let document = try await env.service.openDocument(at: url)
        try FileManager.default.removeItem(at: url)

        document.type("B")
        await #expect(throws: LiteMDError.self) { try await env.service.save(document) }
        #expect(document.conflict == .externalDeleted)

        try await env.service.resolveConflictByKeepingLocal(document)
        #expect(env.directory.read(url) == "AB")
    }

    @Test func autosaveWritesAfterDebounce() async throws {
        let env = TestEnvironment(autosave: true)
        let url = env.directory.file("a.md", "")
        let document = try await env.service.openDocument(at: url)

        document.type("auto")
        env.service.noteTextDidChange(document, isComposing: false)
        #expect(document.saveState == .scheduled)
        #expect(await waitUntil { env.directory.read(url) == "auto" })
        #expect(await waitUntil { document.saveState == .clean })
    }

    /// spec §104：IME 组合期间不自动保存。
    @Test func autosaveWaitsForCompositionCommit() async throws {
        let env = TestEnvironment(autosave: true)
        let url = env.directory.file("a.md", "")
        let document = try await env.service.openDocument(at: url)

        document.type("zhong")
        env.service.noteTextDidChange(document, isComposing: true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(env.fileSystem.writeCount == 0)

        document.applyEdit(range: NSRange(location: 0, length: 5), replacement: "中")
        env.service.noteTextDidChange(document, isComposing: false)
        #expect(await waitUntil { env.directory.read(url) == "中" })
    }
}

@Suite("Saving around file operations")
@MainActor
struct SaveAroundFileOperationTests {
    /// 保存进行中时重命名：先等保存完成再移动，内容跟着文件走，旧路径不会被重新创建。
    @Test func renameWaitsForSaveInProgress() async throws {
        let env = TestEnvironment()
        let workspace = WorkspaceService(fileSystem: LocalFileSystem())
        workspace.onItemMoved = { env.service.itemMoved(from: $0, to: $1) }
        try await workspace.open(env.directory.url)
        let url = env.directory.file("a.md", "old")
        let document = try await env.service.openDocument(at: url)

        document.type(" new")
        env.fileSystem.holdWrites()
        let save = Task { try await env.service.save(document) }
        #expect(await waitUntil { env.fileSystem.writeCount == 1 })

        let rename = Task {
            await env.service.finishPendingSaves(under: url)
            return try await workspace.rename(url, to: "b")
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(FileManager.default.fileExists(atPath: url.path))

        env.fileSystem.releaseWrites()
        try await save.value
        let renamed = try await rename.value
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(env.directory.read(renamed) == "old new")
        #expect(document.fileReference?.url == renamed)
        #expect(!document.isDirty)
    }

    /// 等待中的自动保存在移动前立即执行，而不是之后写回旧路径。
    @Test func pendingAutosaveIsFlushedBeforeFileOperation() async throws {
        let env = TestEnvironment(autosave: true)
        env.service.autosaveDelay = .seconds(30)
        let url = env.directory.file("Notes/a.md", "old")
        let document = try await env.service.openDocument(at: url)

        document.type(" new")
        env.service.noteTextDidChange(document, isComposing: false)
        #expect(document.saveState == .scheduled)

        await env.service.finishPendingSaves(under: url.deletingLastPathComponent())
        #expect(env.directory.read(url) == "old new")
        #expect(!document.isDirty)
    }

    /// 写入期间文件被移走：不能在旧路径重新创建，进入冲突；跟随移动后保存到新位置。
    @Test func saveDoesNotRecreateFileMovedDuringWrite() async throws {
        let env = TestEnvironment()
        let url = env.directory.file("a.md", "old")
        let document = try await env.service.openDocument(at: url)

        document.type(" new")
        env.fileSystem.holdWrites()
        let save = Task { try await env.service.save(document) }
        #expect(await waitUntil { env.fileSystem.writeCount == 1 })

        let moved = env.directory.file("b.md")
        try FileManager.default.moveItem(at: url, to: moved)
        env.fileSystem.releaseWrites()
        await #expect(throws: LiteMDError.self) { try await save.value }

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(env.directory.read(moved) == "old")
        #expect(document.isDirty)
        #expect(document.conflict == .externalDeleted)

        env.service.itemMoved(from: url, to: moved)
        #expect(document.conflict == .none)
        try await env.service.save(document)
        #expect(env.directory.read(moved) == "old new")
    }

    /// 写入期间文件被删除（例如移到废纸篓）：不能把它写回来。
    @Test func saveDoesNotResurrectFileDeletedDuringWrite() async throws {
        let env = TestEnvironment()
        let url = env.directory.file("a.md", "old")
        let document = try await env.service.openDocument(at: url)

        document.type(" new")
        env.fileSystem.holdWrites()
        let save = Task { try await env.service.save(document) }
        #expect(await waitUntil { env.fileSystem.writeCount == 1 })

        try FileManager.default.removeItem(at: url)
        env.fileSystem.releaseWrites()
        await #expect(throws: LiteMDError.self) { try await save.value }

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(document.isDirty)
        #expect(document.conflict == .externalDeleted)
    }

    /// 同一文件只能有一个 Buffer：Save As 到另一个标签页已打开的文件时拒绝。
    @Test func saveAsOntoFileOpenInAnotherTabIsRefused() async throws {
        let env = TestEnvironment()
        let a = env.directory.file("a.md", "A")
        let b = env.directory.file("b.md", "B")
        let first = try await env.service.openDocument(at: a)
        let second = try await env.service.openDocument(at: b)
        second.type("-edited")

        do {
            try await env.service.save(second, to: a)
            Issue.record("Save As should be refused")
        } catch {
            #expect(error.reason == .alreadyOpen)
        }
        #expect(env.directory.read(a) == "A")
        #expect(first.fileReference?.url == a)
        #expect(second.fileReference?.url == b)
        #expect(second.isDirty)

        try await env.service.save(second, to: b)
        #expect(env.directory.read(b) == "B-edited")
    }

    /// 跟随移动只解除“已删除”，外部修改造成的冲突仍需用户处理。
    @Test func followingMoveKeepsExternalModificationConflict() async throws {
        let env = TestEnvironment()
        let url = env.directory.file("a.md", "old")
        let document = try await env.service.openDocument(at: url)
        document.type(" local")
        try externalWrite("new", to: url)
        await env.service.handleFileEvents([FileEvent(url: url, flags: .modified)])
        #expect(document.conflict == .externalModified)

        let moved = env.directory.file("b.md")
        try FileManager.default.moveItem(at: url, to: moved)
        env.service.itemMoved(from: url, to: moved)
        #expect(document.fileReference?.url == moved)
        #expect(document.conflict == .externalModified)
    }
}

@Suite("Version history")
@MainActor
struct VersionHistoryTests {
    @Test func backsUpOriginalContentBeforeFirstOverwriteOnly() async throws {
        let directory = TemporaryDirectory()
        let historyDirectory = TemporaryDirectory()
        let recoveryDirectory = TemporaryDirectory()
        let history = FileVersionHistoryStore(directory: historyDirectory.url)
        let service = DocumentService(
            fileSystem: LocalFileSystem(),
            parser: LiteMDMarkdownParserStub(),
            recoveryStore: FileRecoveryStore(directory: recoveryDirectory.url),
            versionHistory: history
        )
        service.isAutosaveEnabled = false

        let url = directory.file("note.md", "original content")
        let document = try await service.openDocument(at: url)
        document.type(" v1")
        try await service.save(document)
        document.type(" v2")
        try await service.save(document)

        let snapshots = await history.snapshots(for: url)
        #expect(snapshots.count == 1)
        #expect(try String(contentsOf: try #require(snapshots.first).fileURL, encoding: .utf8) == "original content")
        #expect(directory.read(url) == "original content v1 v2")
    }

    @Test func replaceInClosedFileKeepsEncodingLineEndingsAndHistory() async throws {
        let directory = TemporaryDirectory()
        let historyDirectory = TemporaryDirectory()
        let recoveryDirectory = TemporaryDirectory()
        let history = FileVersionHistoryStore(directory: historyDirectory.url)
        let service = DocumentService(
            fileSystem: LocalFileSystem(),
            parser: LiteMDMarkdownParserStub(),
            recoveryStore: FileRecoveryStore(directory: recoveryDirectory.url),
            versionHistory: history
        )
        // 带 BOM 的 UTF-8、Windows 换行：替换后原样保留。
        let url = directory.url.appendingPathComponent("bom.md")
        let bom = Data([0xEF, 0xBB, 0xBF])
        try (bom + Data("旧名称\r\n第二行 旧名称\r\n".utf8)).write(to: url)

        let count = try await service.replaceText(inFileAt: url, SearchQuery(text: "旧名称"), with: "新名称")
        #expect(count == 2)
        #expect(try Data(contentsOf: url) == bom + Data("新名称\r\n第二行 新名称\r\n".utf8))

        // 替换前的版本进了历史，可以找回。
        let snapshots = await history.snapshots(for: url)
        #expect(snapshots.count == 1)

        // 没有匹配时不写文件，也不多存历史。
        #expect(try await service.replaceText(inFileAt: url, SearchQuery(text: "不存在"), with: "x") == 0)
        #expect(await history.snapshots(for: url).count == 1)
    }

    @Test func replaceRefusesFilesThatAreOpenInATab() async throws {
        let env = TestEnvironment()
        let url = env.directory.file("open.md", "hello")
        _ = try await env.service.openDocument(at: url)
        await #expect(throws: LiteMDError.self) {
            try await env.service.replaceText(inFileAt: url, SearchQuery(text: "hello"), with: "bye")
        }
        #expect(env.directory.read(url) == "hello")
    }

    @Test func keepsOneSnapshotPerIntervalAndSkipsDuplicates() async throws {
        let directory = TemporaryDirectory()
        let historyDirectory = TemporaryDirectory()
        let recoveryDirectory = TemporaryDirectory()
        let history = FileVersionHistoryStore(directory: historyDirectory.url)
        let service = DocumentService(
            fileSystem: LocalFileSystem(),
            parser: LiteMDMarkdownParserStub(),
            recoveryStore: FileRecoveryStore(directory: recoveryDirectory.url),
            versionHistory: history,
            historySnapshotInterval: 0
        )
        service.isAutosaveEnabled = false

        let url = directory.file("note.md", "one")
        let document = try await service.openDocument(at: url)
        document.type(" two")
        try await service.save(document)
        try await Task.sleep(for: .milliseconds(5))
        document.type(" three")
        try await service.save(document)

        let snapshots = await service.versionSnapshots(for: document)
        #expect(snapshots.count == 2)
        #expect(try await service.text(of: snapshots[0]) == "one two")
        #expect(try await service.text(of: snapshots[1]) == "one")
        #expect(snapshots[0].byteCount == 7)

        // 与最近一份内容相同的快照不会重复保存。
        await history.storeSnapshot(of: url, data: Data("one two".utf8), date: Date())
        #expect(await history.snapshots(for: url).count == 2)
    }

    /// 历史按路径保存：重命名文件夹后历史跟随文件，旧路径不再留有历史。
    @Test func historyFollowsRenamedFolder() async throws {
        let directory = TemporaryDirectory()
        let historyDirectory = TemporaryDirectory()
        let recoveryDirectory = TemporaryDirectory()
        let history = FileVersionHistoryStore(directory: historyDirectory.url)
        let service = DocumentService(
            fileSystem: LocalFileSystem(),
            parser: LiteMDMarkdownParserStub(),
            recoveryStore: FileRecoveryStore(directory: recoveryDirectory.url),
            versionHistory: history
        )
        service.isAutosaveEnabled = false
        let workspace = WorkspaceService(fileSystem: LocalFileSystem())
        workspace.onItemMoved = { service.itemMoved(from: $0, to: $1) }
        try await workspace.open(directory.url)

        let url = directory.file("Notes/note.md", "original")
        let document = try await service.openDocument(at: url)
        document.type(" v1")
        try await service.save(document)
        #expect(await service.versionSnapshots(for: document).count == 1)

        _ = try await workspace.rename(url.deletingLastPathComponent(), to: "Archive")
        let snapshots = await service.versionSnapshots(for: document)
        #expect(snapshots.count == 1)
        #expect(try await service.text(of: try #require(snapshots.first)) == "original")
        #expect(await history.snapshots(for: url).isEmpty)
    }
}

@Suite("External changes")
@MainActor
struct ExternalChangeTests {
    @Test func cleanDocumentReloadsAutomatically() async throws {
        let env = TestEnvironment()
        let url = env.directory.file("a.md", "old")
        let document = try await env.service.openDocument(at: url)

        try externalWrite("new", to: url)
        await env.service.handleFileEvents([FileEvent(url: url, flags: .modified)])

        #expect(document.text == "new")
        #expect(!document.isDirty)
        #expect(document.conflict == .none)
    }

    @Test func dirtyDocumentEntersConflictInsteadOfReloading() async throws {
        let env = TestEnvironment()
        let url = env.directory.file("a.md", "old")
        let document = try await env.service.openDocument(at: url)
        document.type(" local")

        try externalWrite("new", to: url)
        await env.service.handleFileEvents([FileEvent(url: url, flags: .modified)])

        #expect(document.text == "old local")
        #expect(document.conflict == .externalModified)
    }

    @Test func ownSaveDoesNotTriggerConflict() async throws {
        let env = TestEnvironment()
        let url = env.directory.file("a.md", "old")
        let document = try await env.service.openDocument(at: url)
        document.type("!")
        try await env.service.save(document)

        await env.service.handleFileEvents([FileEvent(url: url, flags: .modified)])
        #expect(document.conflict == .none)
        #expect(document.text == "old!")
    }

    @Test func externalRenameIsFollowed() async throws {
        let env = TestEnvironment()
        let url = env.directory.file("a.md", "content")
        let document = try await env.service.openDocument(at: url)
        let inode = try #require(document.fileReference?.identity?.inode)

        let renamed = env.directory.url.appendingPathComponent("b.md")
        try FileManager.default.moveItem(at: url, to: renamed)
        await env.service.handleFileEvents([
            FileEvent(url: url, flags: .renamed, inode: inode),
            FileEvent(url: renamed, flags: .renamed, inode: inode),
        ])

        #expect(document.fileReference?.url == renamed.standardizedFileURL)
        #expect(document.conflict == .none)
    }

    @Test func externalDeletionIsReported() async throws {
        let env = TestEnvironment()
        let url = env.directory.file("a.md", "content")
        let document = try await env.service.openDocument(at: url)
        try FileManager.default.removeItem(at: url)

        await env.service.handleFileEvents([FileEvent(url: url, flags: .removed)])
        #expect(document.conflict == .externalDeleted)
    }
}

@Suite("Recovery")
@MainActor
struct RecoveryTests {
    /// spec §181：快照 → 强制退出 → 重启 → 提示恢复，内容与快照一致。
    @Test func recoversUnsavedEditsAfterCrash() async throws {
        let env = TestEnvironment()
        let url = env.directory.file("a.md", "saved")
        let document = try await env.service.openDocument(at: url)
        document.type(" + unsaved")
        env.service.noteTextDidChange(document, isComposing: false)
        let untitled = env.service.newDocument(text: "scratch")
        env.service.noteTextDidChange(untitled, isComposing: false)

        let recoveryURL = env.recoveryDirectory.url
        #expect(await waitUntil { await FileRecoveryStore(directory: recoveryURL).entries().count == 2 })

        // “重启”：新的服务实例，共享同一个 Recovery 目录。
        let store = FileRecoveryStore(directory: recoveryURL)
        let relaunched = DocumentService(fileSystem: LocalFileSystem(), parser: LiteMDMarkdownParserStub(), recoveryStore: store)
        relaunched.isAutosaveEnabled = false
        let entries = await relaunched.pendingRecoveryEntries()
        #expect(entries.count == 2)

        let failures = await relaunched.recover(entries)
        #expect(failures.isEmpty)
        let texts = Set(relaunched.documents.map(\.text))
        #expect(texts == ["saved + unsaved", "scratch"])
        let allDirty = relaunched.documents.allSatisfy(\.isDirty)
        #expect(allDirty)
        #expect(env.directory.read(url) == "saved")
    }

    /// 崩溃后原文件被其他程序改成 LF：恢复的内容仍按编辑时的换行符保存。
    @Test func recoveryKeepsLineEndingsOfEditedFile() async throws {
        let env = TestEnvironment()
        let url = env.directory.file("a.md", "one\r\ntwo")
        let document = try await env.service.openDocument(at: url)
        document.type(" edited")
        env.service.noteTextDidChange(document, isComposing: false)
        let recoveryURL = env.recoveryDirectory.url
        #expect(await waitUntil { await FileRecoveryStore(directory: recoveryURL).entries().count == 1 })

        try externalWrite("one\ntwo", to: url)
        let relaunched = DocumentService(fileSystem: LocalFileSystem(), parser: LiteMDMarkdownParserStub(), recoveryStore: FileRecoveryStore(directory: recoveryURL))
        relaunched.isAutosaveEnabled = false
        let failures = await relaunched.recover(await relaunched.pendingRecoveryEntries())
        #expect(failures.isEmpty)

        let recovered = try #require(relaunched.documents.first)
        #expect(recovered.text == "one\ntwo edited")
        #expect(recovered.fileReference?.lineEnding == .crlf)
    }

    @Test func savingRemovesRecoverySnapshot() async throws {
        let env = TestEnvironment()
        let url = env.directory.file("a.md", "x")
        let document = try await env.service.openDocument(at: url)
        document.type("y")
        env.service.noteTextDidChange(document, isComposing: false)

        let recoveryURL = env.recoveryDirectory.url
        #expect(await waitUntil { await FileRecoveryStore(directory: recoveryURL).entries().count == 1 })

        try await env.service.save(document)
        #expect(await waitUntil { await FileRecoveryStore(directory: recoveryURL).entries().isEmpty })
    }
}

struct LiteMDMarkdownParserStub: MarkdownParsing {
    func parse(_ text: String, documentID: DocumentID, revision: Int, options: MarkdownParseOptions) async -> ParseResult {
        ParseResult(documentID: documentID, revision: revision)
    }
}
