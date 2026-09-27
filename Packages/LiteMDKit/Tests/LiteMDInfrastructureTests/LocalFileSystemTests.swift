import Foundation
import LiteMDDomain
import LiteMDInfrastructure
import Testing

final class TemporaryDirectory {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiteMDTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String, _ contents: String? = nil) -> URL {
        let file = url.appendingPathComponent(name)
        if let contents {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(contents.utf8).write(to: file)
        }
        return file
    }
}

@Suite("LocalFileSystem")
struct LocalFileSystemTests {
    let fileSystem = LocalFileSystem()
    let directory = TemporaryDirectory()

    @Test func readReturnsDecodedTextAndRevision() async throws {
        let url = directory.file("a.md", "# A\r\nb\r\n")
        let loaded = try await fileSystem.readText(at: url)
        #expect(loaded.text == "# A\nb\n")
        #expect(loaded.lineEnding == .crlf)
        #expect(loaded.diskRevision.fileSize == 8)
        #expect(loaded.diskRevision.contentHash?.count == 64)
        #expect(loaded.identity != nil)
    }

    @Test func atomicWriteReplacesContentAndPreservesPermissions() async throws {
        let url = directory.file("a.md", "old")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        let revision = try await fileSystem.writeText("new\ncontent", encoding: .utf8WithBOM, lineEnding: .crlf, to: url)

        let data = try Data(contentsOf: url)
        #expect(data == Data([0xEF, 0xBB, 0xBF]) + Data("new\r\ncontent".utf8))
        #expect(revision.fileSize == Int64(data.count))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.url.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)

        let current = try await fileSystem.diskRevision(at: url, includeHash: true)
        #expect(current == revision)
    }

    @Test func writeCreatesNewFile() async throws {
        let url = directory.file("new.md")
        _ = try await fileSystem.writeText("hello", encoding: .utf8, lineEnding: .lf, to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "hello")
    }

    @Test func writeFollowsSymlinks() async throws {
        let target = directory.file("target.md", "old")
        let link = directory.file("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        _ = try await fileSystem.writeText("new", encoding: .utf8, lineEnding: .lf, to: link)

        #expect(try String(contentsOf: target, encoding: .utf8) == "new")
        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
    }

    @Test func missingFileHasNoRevision() async throws {
        #expect(try await fileSystem.diskRevision(at: directory.file("missing.md"), includeHash: false) == nil)
        await #expect(throws: LiteMDError.self) {
            try await fileSystem.readText(at: directory.file("missing.md"))
        }
    }

    @Test func createFileAndMoveNeverOverwrite() async throws {
        let existing = directory.file("a.md", "keep me")
        await #expect(throws: LiteMDError.self) {
            try await fileSystem.createFile(at: existing, contents: Data("x".utf8))
        }

        let other = directory.file("b.md", "other")
        do {
            try await fileSystem.moveItem(from: other, to: existing)
            Issue.record("move should fail")
        } catch {
            #expect(error.reason == .alreadyExists)
        }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "keep me")
    }

    @Test func caseOnlyRenameIsAllowed() async throws {
        let url = directory.file("readme.md", "x")
        let renamed = directory.url.appendingPathComponent("README.md")
        try await fileSystem.moveItem(from: url, to: renamed)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
        #expect(names.contains("README.md"))
    }

    /// a.md 是指向 b.md 的链接：跟随链接后两者是同一文件，但这不是大小写重命名，不能覆盖 b.md。
    @Test func renamingSymlinkOntoItsTargetIsRefused() async throws {
        let target = directory.file("b.md", "real content")
        let link = directory.file("a.md")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "b.md")

        do {
            try await fileSystem.moveItem(from: link, to: target)
            Issue.record("move should fail")
        } catch {
            #expect(error.reason == .alreadyExists)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        #expect(try String(contentsOf: target, encoding: .utf8) == "real content")
    }

    @Test func replaceOnlyWriteDoesNotRecreateMissingFile() async throws {
        let url = directory.file("gone.md")
        do {
            _ = try await fileSystem.writeText("x", encoding: .utf8, lineEnding: .lf, to: url, requireExisting: true)
            Issue.record("write should fail")
        } catch {
            #expect(error.kind == .conflict)
            #expect(error.reason == .externalDeletion)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func listsDirectoriesFirstAndHonorsIgnoreRules() async throws {
        _ = directory.file("b.md", "")
        _ = directory.file("A.md", "")
        _ = directory.file("sub/c.md", "")
        _ = directory.file(".hidden.md", "")
        _ = directory.file("node_modules/x.md", "")

        let entries = try await fileSystem.contentsOfDirectory(at: directory.url, rules: WorkspaceIgnoreRules())
        #expect(entries.map(\.name) == ["sub", "A.md", "b.md"])

        let markdown = try await fileSystem.markdownFiles(under: directory.url, rules: WorkspaceIgnoreRules())
        #expect(Set(markdown.map(\.lastPathComponent)) == ["A.md", "b.md", "c.md"])
    }
}

@Suite("RecoveryStore")
struct RecoveryStoreTests {
    let directory = TemporaryDirectory()

    @Test func storesLoadsAndRemovesEntries() async throws {
        let store = FileRecoveryStore(directory: directory.url)
        let id = DocumentID()
        let entry = RecoveryEntry(
            documentID: id,
            originalURL: URL(fileURLWithPath: "/tmp/a.md"),
            displayName: "a.md",
            knownDiskRevision: DiskRevision(modifiedAtNanoseconds: 1_700_000_000_123_456_789, fileSize: 4, contentHash: "h"),
            encoding: .utf8,
            lineEnding: .lf,
            timestamp: Date()
        )
        try await store.store(entry, content: "中文 content")

        // 新实例模拟重启。
        let reopened = FileRecoveryStore(directory: directory.url)
        #expect(await reopened.entries() == [entry])
        #expect(try await reopened.content(for: id) == "中文 content")

        await reopened.remove(id)
        #expect(await FileRecoveryStore(directory: directory.url).entries().isEmpty)
    }
}

@Suite("VersionHistoryStore")
struct VersionHistoryStoreTests {
    let directory = TemporaryDirectory()

    @Test func historyFollowsMovedFilesAndFolders() async throws {
        let store = FileVersionHistoryStore(directory: directory.url)
        let file = URL(fileURLWithPath: "/w/a.md")
        let nested = URL(fileURLWithPath: "/w/dir/b.md")
        let sibling = URL(fileURLWithPath: "/w/dir-2/c.md")
        let renamed = URL(fileURLWithPath: "/w/renamed.md")
        await store.storeSnapshot(of: file, data: Data("a".utf8), date: Date())
        await store.storeSnapshot(of: nested, data: Data("b".utf8), date: Date())
        await store.storeSnapshot(of: sibling, data: Data("c".utf8), date: Date())
        // 目标路径上残留着一个已经不在的文件的历史。
        await store.storeSnapshot(of: renamed, data: Data("stale".utf8), date: Date())

        await store.moveSnapshots(from: file, to: renamed)
        await store.moveSnapshots(from: URL(fileURLWithPath: "/w/dir"), to: URL(fileURLWithPath: "/w/archive"))

        #expect(await store.snapshots(for: file).isEmpty)
        let moved = await store.snapshots(for: renamed)
        #expect(moved.count == 1)
        #expect(try Data(contentsOf: try #require(moved.first).fileURL) == Data("a".utf8))
        #expect(await store.snapshots(for: nested).isEmpty)
        #expect(await store.snapshots(for: URL(fileURLWithPath: "/w/archive/b.md")).count == 1)
        #expect(await store.snapshots(for: sibling).count == 1)
    }
}
