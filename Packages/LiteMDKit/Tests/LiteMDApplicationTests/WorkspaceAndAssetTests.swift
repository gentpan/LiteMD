import Foundation
@testable import LiteMDApplication
import LiteMDDomain
import LiteMDInfrastructure
import Testing

@Suite("AssetService")
struct AssetServiceTests {
    let directory = TemporaryDirectory()
    let service = AssetService(fileSystem: LocalFileSystem())

    @Test func importsClipboardImageIntoAssetsFolder() async throws {
        let document = directory.file("notes/README.md", "# x")
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 17
        components.hour = 17; components.minute = 35; components.second = 0
        let date = try #require(Calendar(identifier: .gregorian).date(from: components))

        let first = try await service.importImageData(Data([1, 2, 3]), fileExtension: "PNG", forDocumentAt: document, location: AssetLocation(), date: date)
        #expect(first.markdownPath == "assets/image-20260917-173500.png")
        #expect(FileManager.default.fileExists(atPath: first.fileURL.path))

        // spec §132：同名时不覆盖，自动追加序号。
        let second = try await service.importImageData(Data([4]), fileExtension: "png", forDocumentAt: document, location: AssetLocation(), date: date)
        #expect(second.markdownPath == "assets/image-20260917-173500-2.png")
        #expect(try Data(contentsOf: first.fileURL) == Data([1, 2, 3]))
    }

    @Test func copiesDroppedImagesWithSafeNames() async throws {
        let document = directory.file("doc/a.md", "")
        let source = directory.file("outside/Screenshot 2026-09-17 at 17.35.00.png", "img")

        let result = try await service.importFile(at: source, forDocumentAt: document, location: AssetLocation(mode: .images))
        #expect(result.markdownPath == "images/Screenshot-2026-09-17-at-17.35.00.png")
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func referencesImagesAlreadyInsideDocumentFolder() async throws {
        let document = directory.file("doc/a.md", "")
        let existing = directory.file("doc/pics/x.png", "img")
        let result = try await service.importFile(at: existing, forDocumentAt: document, location: AssetLocation())
        #expect(result.markdownPath == "pics/x.png")
        #expect(result.fileURL == existing)
    }

    @Test func customNestedFolderIsCreated() async throws {
        let document = directory.file("doc/a.md", "")
        let result = try await service.importImageData(Data([1]), fileExtension: "jpg", forDocumentAt: document, location: AssetLocation(mode: .custom, customPath: "media/2026/"))
        #expect(result.markdownPath.hasPrefix("media/2026/image-"))
    }

    /// 失败时按图片插入报告，而不是“无法打开 image-….png”。
    @Test func failuresAreReportedAsAssetErrors() async throws {
        let document = directory.file("doc/a.md", "")
        // assets 被一个普通文件占用，图片无法写入。
        directory.file("doc/assets", "not a folder")

        do {
            _ = try await service.importImageData(Data([1]), fileExtension: "png", forDocumentAt: document, location: AssetLocation())
            Issue.record("import should fail")
        } catch {
            #expect(error.kind == .asset)
        }
    }

    @Test func relativePaths() {
        let base = URL(fileURLWithPath: "/a/b/c")
        #expect(AssetService.relativePath(from: base, to: URL(fileURLWithPath: "/a/b/c/d.png")) == "d.png")
        #expect(AssetService.relativePath(from: base, to: URL(fileURLWithPath: "/a/x/y.png")) == "../../x/y.png")
        #expect(AssetService.sanitizedBaseName("my (final) image?") == "my-final-image")
        #expect(AssetService.sanitizedBaseName("截图 1") == "截图-1")
    }
}

@Suite("WorkspaceService")
@MainActor
struct WorkspaceServiceTests {
    @Test func loadsTreeLazilyAndFiltersFiles() async throws {
        let directory = TemporaryDirectory()
        directory.file("README.md", "")
        directory.file("image.png", "")
        directory.file("script.js", "")
        directory.file("Blog/Hello.md", "")

        let workspace = WorkspaceService(fileSystem: LocalFileSystem())
        try await workspace.open(directory.url)

        let root = try #require(workspace.root)
        #expect(root.children?.map(\.name) == ["Blog", "image.png", "README.md"])
        let blog = try #require(root.children?.first)
        #expect(blog.children == nil)

        try await workspace.loadChildren(of: blog)
        #expect(blog.children?.map(\.name) == ["Hello.md"])
        #expect(workspace.node(for: directory.url.appendingPathComponent("Blog/Hello.md"))?.name == "Hello.md")
        #expect(await workspace.allMarkdownFiles().count == 2)
    }

    @Test func fileOperationsUseUniqueNamesAndNotifyMoves() async throws {
        let directory = TemporaryDirectory()
        let workspace = WorkspaceService(fileSystem: LocalFileSystem())
        try await workspace.open(directory.url)

        var moves: [(URL, URL)] = []
        workspace.onItemMoved = { moves.append(($0, $1)) }

        let first = try await workspace.createMarkdownFile(in: directory.url)
        let second = try await workspace.createMarkdownFile(in: directory.url)
        #expect(first.lastPathComponent == "Untitled.md")
        #expect(second.lastPathComponent == "Untitled 2.md")

        let renamed = try await workspace.rename(first, to: "Ideas")
        #expect(renamed.lastPathComponent == "Ideas.md")

        let folder = try await workspace.createFolder(in: directory.url)
        let moved = try await workspace.move(renamed, into: folder)
        #expect(moved.path.hasSuffix("New Folder/Ideas.md"))
        #expect(moves.count == 2)

        let copy = try await workspace.duplicate(moved)
        #expect(copy.lastPathComponent == "Ideas copy.md")

        await #expect(throws: LiteMDError.self) {
            try await workspace.rename(second, to: "a/b")
        }
        await #expect(throws: LiteMDError.self) {
            try await workspace.move(folder, into: folder)
        }
    }

    /// 重名等失败按文件夹操作报告，而不是“无法打开 b.md”。
    @Test func failedOperationsAreReportedAsWorkspaceErrors() async throws {
        let directory = TemporaryDirectory()
        let a = directory.file("a.md", "a")
        directory.file("b.md", "b")
        let workspace = WorkspaceService(fileSystem: LocalFileSystem())
        try await workspace.open(directory.url)

        do {
            try await workspace.rename(a, to: "b")
            Issue.record("rename should fail")
        } catch {
            #expect(error.kind == .workspace)
            #expect(error.reason == .alreadyExists)
        }
        do {
            try await workspace.move(a, into: directory.file("missing"))
            Issue.record("move should fail")
        } catch {
            #expect(error.kind == .workspace)
        }
        #expect(directory.read(a) == "a")
    }

    /// 同一目录的两次读取交错返回时，较早的结果不能覆盖较新的结果。
    @Test func staleDirectoryListingIsDiscarded() async throws {
        let directory = TemporaryDirectory()
        directory.file("a.md", "")
        let fileSystem = GatedFileSystem()
        let workspace = WorkspaceService(fileSystem: fileSystem)
        try await workspace.open(directory.url)
        let root = try #require(workspace.root)

        fileSystem.holdNextDirectoryListing()
        let stale = Task { try await workspace.loadChildren(of: root) }
        #expect(await waitUntil { fileSystem.heldListingCount == 1 })

        directory.file("b.md", "")
        try await workspace.loadChildren(of: root)
        #expect(root.children?.map(\.name) == ["a.md", "b.md"])

        fileSystem.releaseDirectoryListings()
        try await stale.value
        #expect(root.children?.map(\.name) == ["a.md", "b.md"])
        #expect(!root.isLoading)
    }

    @Test func renamingOpenDocumentUpdatesItsPath() async throws {
        let env = TestEnvironment()
        let workspace = WorkspaceService(fileSystem: LocalFileSystem())
        workspace.onItemMoved = { env.service.itemMoved(from: $0, to: $1) }
        workspace.onItemTrashed = { env.service.itemTrashed(at: $0) }

        let folder = env.directory.file("Notes/a.md", "x").deletingLastPathComponent()
        try await workspace.open(env.directory.url)
        let document = try await env.service.openDocument(at: folder.appendingPathComponent("a.md"))

        let renamedFolder = try await workspace.rename(folder, to: "Archive")
        #expect(document.fileReference?.url == renamedFolder.appendingPathComponent("a.md").standardizedFileURL)

        document.type("y")
        try await env.service.save(document)
        #expect(env.directory.read(renamedFolder.appendingPathComponent("a.md")) == "xy")
    }
}

@Suite("WorkspaceSearcher")
struct WorkspaceSearcherTests {
    @Test func findsMatchesWithLineColumnAndSnippet() {
        let text = "# LiteMD\n\n  LiteMD is a Markdown editor\n中文 litemd"
        let matches = WorkspaceSearcher.matches(of: SearchQuery(text: "litemd"), in: text)
        #expect(matches.map(\.line) == [1, 3, 4])
        #expect(matches.map(\.column) == [3, 3, 4])
        #expect(matches[1].snippet == "LiteMD is a Markdown editor")
        #expect(matches[1].snippetMatchRange == NSRange(location: 0, length: 6))

        let sensitive = WorkspaceSearcher.matches(of: SearchQuery(text: "litemd", caseSensitive: true), in: text)
        #expect(sensitive.count == 1)
    }

    @Test func searchesFilesAndPrefersOpenDocumentContent() async throws {
        let directory = TemporaryDirectory()
        let a = directory.file("a.md", "alpha LiteMD")
        let b = directory.file("b.md", "beta")
        let c = directory.file("c.md", "gamma LiteMD LiteMD")

        let searcher = WorkspaceSearcher(fileSystem: LocalFileSystem())
        var results: [URL: Int] = [:]
        for await result in searcher.search(SearchQuery(text: "litemd"), files: [a, b, c], openDocuments: [b: "unsaved LiteMD"]) {
            results[result.url] = result.matches.count
        }
        #expect(results == [a: 1, b: 1, c: 2])
    }
}
