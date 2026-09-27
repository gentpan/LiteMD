import Foundation
@testable import LiteMDApplication
import LiteMDDomain
import LiteMDInfrastructure
import Testing

@Suite("Wiki links and backlinks")
struct LinkGraphTests {
    @Test func resolvesByPathThenNamePreferringSameFolder() {
        let root = URL(fileURLWithPath: "/w")
        let files = [
            URL(fileURLWithPath: "/w/Plan.md"),
            URL(fileURLWithPath: "/w/Projects/Plan.md"),
            URL(fileURLWithPath: "/w/Projects/Deep/Other.md"),
            URL(fileURLWithPath: "/w/日记/Café.md"),
        ]
        let current = URL(fileURLWithPath: "/w/Projects/Index.md")
        #expect(WikiLinkResolver.resolve("Plan", from: current, root: root, candidates: files)?.path == "/w/Plan.md")
        #expect(WikiLinkResolver.resolve("Projects/Plan", from: current, root: root, candidates: files)?.path == "/w/Projects/Plan.md")
        #expect(WikiLinkResolver.resolve("other", from: current, root: root, candidates: files)?.path == "/w/Projects/Deep/Other.md")
        // 组合字符与预组合字符视为相同。
        #expect(WikiLinkResolver.resolve("cafe\u{301}", from: current, root: root, candidates: files)?.path == "/w/日记/Café.md")
        #expect(WikiLinkResolver.resolve("Missing", from: current, root: root, candidates: files) == nil)
        #expect(WikiLinkResolver.fileName(for: "a/b:c") == "a b c")
    }

    /// 文件名里的点不是扩展名：补全插入的 `[[2024.01.05]]` 要能打开 `2024.01.05.md`。
    @Test func namesContainingDotsResolveToMarkdownFiles() {
        let root = URL(fileURLWithPath: "/w")
        let files = [
            URL(fileURLWithPath: "/w/Journal/2024.01.05.md"),
            URL(fileURLWithPath: "/w/README.zh.md"),
            URL(fileURLWithPath: "/w/notes.txt"),
        ]
        let current = URL(fileURLWithPath: "/w/Index.md")
        #expect(WikiLinkResolver.resolve("2024.01.05", from: current, root: root, candidates: files)?.path == "/w/Journal/2024.01.05.md")
        #expect(WikiLinkResolver.resolve("README.zh", from: current, root: root, candidates: files)?.path == "/w/README.zh.md")
        #expect(WikiLinkResolver.resolve("README.zh.md", from: current, root: root, candidates: files)?.path == "/w/README.zh.md")
        #expect(WikiLinkResolver.resolve("Notes.TXT", from: current, root: root, candidates: files)?.path == "/w/notes.txt")
    }

    @Test func findsWikiAndRelativeMarkdownBacklinks() async throws {
        let directory = TemporaryDirectory()
        let target = directory.file("Notes/Plan.md", "# Plan")
        let a = directory.file("A.md", "See [[Plan]] and [[Plan#Goals|goals]].\n\n`[[Plan]]` in code")
        let b = directory.file("Notes/B.md", "Relative [plan](Plan.md) and [web](https://example.com/Plan.md)")
        let c = directory.file("C.md", "Nothing here [[Other]]")
        let index = BacklinkIndex(fileSystem: LocalFileSystem())
        let files = [target, a, b, c]

        let backlinks = await index.backlinks(to: target, root: directory.url, files: files)
        #expect(backlinks.count == 3)
        #expect(backlinks.map(\.sourceURL.lastPathComponent) == ["A.md", "A.md", "B.md"])
        #expect(backlinks[0].kind == .wikiLink)
        #expect(backlinks[0].line == 1)
        #expect(backlinks[2].kind == .markdownLink)
        #expect(backlinks[2].snippet.hasPrefix("Relative [plan](Plan.md)"))
    }

    @Test func backlinksFindNotesWithDotsInTheirNames() async throws {
        let directory = TemporaryDirectory()
        let target = directory.file("2024.01.05.md", "# Day")
        let source = directory.file("Index.md", "See [[2024.01.05]]")
        let index = BacklinkIndex(fileSystem: LocalFileSystem())

        let backlinks = await index.backlinks(to: target, root: directory.url, files: [target, source])
        #expect(backlinks.map(\.sourceURL) == [source])
    }
}
