import Foundation
import LiteMDDomain
@testable import LiteMDMarkdown
import Testing

@Suite("MarkdownParser")
struct MarkdownParserTests {
    let parser = MarkdownParser(fileURLPrefix: "litemd-asset://file")

    private func parse(_ text: String) -> ParseResult {
        parser.parseSynchronously(text, documentID: DocumentID(), revision: 7)
    }

    @Test func buildsOutlineWithOffsetsAndAnchors() {
        let text = "# LiteMD\n\n## 介绍\n\ntext\n\n### Editor\n\n## 介绍\n"
        let result = parse(text)
        #expect(result.revision == 7)
        #expect(result.headings.map(\.level) == [1, 2, 3, 2])
        #expect(result.headings.map(\.title) == ["LiteMD", "介绍", "Editor", "介绍"])
        #expect(result.headings.map(\.line) == [1, 3, 7, 9])
        #expect(result.headings.map(\.anchor) == ["litemd", "介绍", "editor", "介绍-1"])

        let string = text as NSString
        for heading in result.headings {
            #expect(string.substring(from: heading.offset).hasPrefix("#"))
        }
    }

    @Test func frontMatterKeepsLineNumbersAligned() {
        let result = parse("---\ntitle: LiteMD\ntags:\n  - a\n---\n# Heading\n")
        #expect(result.headings.first?.line == 6)
        #expect(result.html.contains("class=\"front-matter\""))
        #expect(result.html.contains("title: LiteMD"))
        #expect(!result.html.contains("<hr"))
    }

    @Test func rendersGFMBlocksWithSourceLines() {
        let result = parse("- [x] done\n- [ ] todo\n\n| A | B |\n| :-- | --: |\n| 1 | 2 |\n\n~~old~~\n")
        #expect(result.html.contains("<ul class=\"contains-task-list\" data-line=\"1\">"))
        #expect(result.html.contains("<input type=\"checkbox\" disabled checked> done"))
        #expect(result.html.contains("<th style=\"text-align: left\">A</th>"))
        #expect(result.html.contains("<td style=\"text-align: right\">2</td>"))
        #expect(result.html.contains("<del>old</del>"))
    }

    @Test func escapesTextAndCode() {
        let result = parse("a < b & c\n\n```html\n<script>alert(1)</script>\n```\n")
        #expect(result.html.contains("a &lt; b &amp; c"))
        #expect(result.html.contains("<code class=\"language-html\">&lt;script&gt;"))
        #expect(result.codeBlocks == [CodeBlockItem(language: "html", startLine: 3, endLine: 5)])
    }

    @Test func sanitizesDangerousHTMLAndURLs() {
        let result = parse("""
        <script>alert(1)</script>
        <img src="x.png" onerror="alert(1)">
        <iframe src="https://example.com"></iframe>

        [bad](javascript:alert(1)) [ok](https://litemd.app) [local](notes/a.md)

        <a href="jav&#x61;script:alert(1)">entity</a> <kbd>⌘</kbd>
        """)
        #expect(!result.html.contains("<script"))
        #expect(!result.html.contains("alert(1)</script>"))
        #expect(!result.html.contains("onerror"))
        #expect(!result.html.contains("<iframe"))
        #expect(!result.html.lowercased().contains("javascript:"))
        #expect(result.html.contains("<a href=\"https://litemd.app\">ok</a>"))
        #expect(result.html.contains("<a href=\"notes/a.md\">local</a>"))
        #expect(result.html.contains("<kbd>⌘</kbd>"))
    }

    @Test func rewritesFileImageURLsAndCollectsImages() {
        let result = parse("![shot](assets/a.png) ![abs](file:///Users/me/b%20c.png) ![bad](javascript:x)")
        #expect(result.html.contains("src=\"assets/a.png\""))
        #expect(result.html.contains("src=\"litemd-asset://file/Users/me/b%20c.png\""))
        #expect(!result.html.contains("javascript"))
        #expect(result.images.map(\.source) == ["assets/a.png", "file:///Users/me/b%20c.png", "javascript:x"])
    }

    @Test func doesNotConvertQuotesToSmartQuotes() {
        #expect(parse("\"quoted\" -- dash").html.contains("\"quoted\" -- dash"))
    }
}

@Suite("DocumentStatistics")
struct DocumentStatisticsTests {
    @Test func countsEnglishWords() {
        let stats = DocumentStatisticsCounter.compute("# Hello, world!\n\nLiteMD don't stop.")
        #expect(stats.words == 5)
        #expect(stats.lines == 3)
    }

    @Test func countsCJKCharactersAsWords() {
        let stats = DocumentStatisticsCounter.compute("LiteMD 是编辑器\nかな")
        #expect(stats.words == 1 + 4 + 2)
        #expect(stats.characters == "LiteMD 是编辑器かな".count)
        #expect(stats.lines == 2)
    }

    @Test func charactersCountGraphemesNotUnits() {
        let stats = DocumentStatisticsCounter.compute("👨‍👩‍👧 é")
        #expect(stats.characters == 3)
    }

    @Test func emptyDocument() {
        let stats = DocumentStatisticsCounter.compute("")
        #expect(stats == DocumentStatistics(words: 0, characters: 0, lines: 1, readingMinutes: 0))
    }
}

@Suite("MarkdownHighlighter")
struct MarkdownHighlighterTests {
    let highlighter = MarkdownHighlighter()

    private func kinds(_ text: String, at substring: String) -> Set<HighlightKind> {
        let range = (text as NSString).range(of: substring)
        return Set(highlighter.tokens(in: text).filter { NSIntersectionRange($0.range, range).length > 0 }.map(\.kind))
    }

    @Test func headingsAndMarkers() {
        let text = "## Title **bold**"
        let tokens = highlighter.tokens(in: text)
        #expect(tokens.first == HighlightToken(range: NSRange(location: 0, length: 17), kind: .heading2))
        #expect(tokens.contains(HighlightToken(range: NSRange(location: 0, length: 2), kind: .marker)))
        #expect(tokens.contains(HighlightToken(range: NSRange(location: 9, length: 8), kind: .strong)))
    }

    @Test func tokensAreSortedAndLineBounded() {
        let text = "# A\n\n```\ncode **not bold**\n```\n\n> quote *em*\n- [x] done\n"
        let tokens = highlighter.tokens(in: text)
        #expect(tokens.map(\.range.location) == tokens.map(\.range.location).sorted())
        let string = text as NSString
        for token in tokens {
            #expect(!string.substring(with: token.range).contains("\n"))
        }
    }

    @Test func codeBlockContentIsNotParsedInline() {
        let text = "```\ncode **not bold**\n```"
        #expect(kinds(text, at: "not bold") == [.codeBlock])
    }

    @Test func inlineConstructs() {
        let text = "Use `a*b*c` and [link](https://x.y) ![img](a.png) ~~gone~~ https://litemd.app"
        #expect(kinds(text, at: "a*b*c").contains(.inlineCode))
        #expect(!kinds(text, at: "a*b*c").contains(.emphasis))
        #expect(kinds(text, at: "link").contains(.link))
        #expect(kinds(text, at: "https://x.y").contains(.url))
        #expect(kinds(text, at: "img").contains(.image))
        #expect(kinds(text, at: "gone").contains(.strikethrough))
        #expect(kinds(text, at: "litemd.app").contains(.url))
    }

    @Test func snakeCaseIsNotItalic() {
        #expect(!kinds("snake_case_name", at: "case").contains(.emphasis))
    }

    @Test func tablesAndFrontMatter() {
        let text = "---\ntitle: x\n---\n| A | B |\n| --- | --- |\n| 1 | 2 |"
        #expect(kinds(text, at: "title").contains(.frontMatter))
        let pipeTokens = highlighter.tokens(in: text).filter { $0.kind == .table }
        #expect(pipeTokens.count == 3 + 1 + 3)
    }

    @Test func inlineCodeAtLineStartDoesNotOpenFence() {
        let text = "```ls``` lists files\n**b**"
        #expect(kinds(text, at: "**b**").contains(.strong))
        #expect(!kinds(text, at: "**b**").contains(.codeBlock))
    }

    @Test func largeDocumentIsFast() {
        let paragraph = "## Heading\n\nSome **bold** and *italic* with `code` and [link](https://litemd.app).\n- [ ] task item\n\n"
        let text = String(repeating: paragraph, count: 10_000)
        let start = ContinuousClock.now
        let tokens = highlighter.tokens(in: text)
        let elapsed = ContinuousClock.now - start
        #expect(tokens.count > 100_000)
        #expect(elapsed < .seconds(3))
    }
}

@Suite("Copy As")
struct CopyAsTests {
    let parser = MarkdownParser()

    @Test func plainTextStripsSyntaxButKeepsStructure() {
        let markdown = "# Title\n\nSome **bold** and `code` with [link](https://x.y).\n\n- one\n- [x] two\n\n1. first\n2. second\n\n> quote\n\n```\nlet a = 1\n```"
        #expect(parser.plainText(from: markdown) == "Title\n\nSome bold and code with link.\n\n• one\n☑ two\n\n1. first\n2. second\n\nquote\n\nlet a = 1")
    }

    @Test func htmlFragmentHasNoSourceLineAttributes() {
        let html = parser.htmlFragment(from: "# Hi\n\n**x**")
        #expect(html == "<h1 id=\"hi\">Hi</h1>\n<p><strong>x</strong></p>")
    }

    @Test func htmlFragmentRendersWikiLinksAndMath() {
        let html = parser.htmlFragment(from: "[[Note|Alias]] and $\\{1,2\\}$")
        #expect(html == "<p><span class=\"wikilink\">Alias</span> and <span class=\"math math-inline\">\\{1,2\\}</span></p>")
    }

    @Test func xhtmlFragmentSharesHeadingAnchorsWithBody() {
        let fragment = parser.xhtmlFragment(from: "# Intro [[Note|Alias]]\n\n$x_1$ and ![[pic.png]]")
        #expect(fragment.headings.map(\.anchor) == ["intro-alias"])
        #expect(fragment.html.contains("<h1 id=\"intro-alias\">Intro <span class=\"wikilink\">Alias</span></h1>"))
        #expect(fragment.html.contains("<code class=\"math\">x_1</code>"))
        #expect(fragment.html.contains("<img class=\"wikilink-embed\" src=\"pic.png\" alt=\"pic.png\"/>"))
    }

    @Test func plainTextKeepsWikiLinkTextAndMathSource() {
        #expect(parser.plainText(from: "See [[Note|Alias]] and $\\{1\\}$, `[[code]]`") == "See Alias and $\\{1\\}$, [[code]]")
    }
}

@Suite("Highlight extension")
struct HighlightExtensionTests {
    @Test func rendersMarkAndLeavesInvalidMarkersAlone() {
        let parser = MarkdownParser()
        let html = parser.parseSynchronously("a ==mark== b == c == d `==code==`", documentID: DocumentID(), revision: 0).html
        #expect(html.contains("a <mark>mark</mark> b == c == d <code>==code==</code>"))
        #expect(parser.plainText(from: "==hi== there") == "hi there")
    }
}

@Suite("Markdown extensions")
struct MarkdownExtensionRenderingTests {
    private func render(_ text: String) -> ParseResult {
        MarkdownParser(fileURLPrefix: "litemd-asset://file").parseSynchronously(text, documentID: DocumentID(), revision: 1)
    }

    @Test func rendersWikiLinksWithoutMarkdownInterference() {
        let result = render("# About [[Project_Plan|the *plan*]]\n\nSee [[Notes/日记#今天]] and ![[pic.png]].")
        #expect(result.html.contains("<a class=\"wikilink\" href=\"litemd-wiki:Project_Plan\">the *plan*</a>"))
        #expect(result.html.contains("href=\"litemd-wiki:Notes/%E6%97%A5%E8%AE%B0#%E4%BB%8A%E5%A4%A9\""))
        #expect(result.html.contains("<img class=\"wikilink-embed\" src=\"pic.png\""))
        #expect(result.headings.first?.title == "About the *plan*")
        #expect(result.wikiLinks.map(\.target) == ["Project_Plan", "Notes/日记", "pic.png"])
        #expect(!result.html.contains("\u{E000}"))
    }

    @Test func rendersMathKeepingBackslashesAndLineNumbers() {
        let result = render("Inline $\\{a_1\\}$ here.\n\n$$\n\\frac{1}{2}\n$$\n\n## After")
        #expect(result.html.contains("<span class=\"math math-inline\">\\{a_1\\}</span>"))
        #expect(result.html.contains("<span class=\"math math-display\">\\frac{1}{2}</span>"))
        #expect(result.headings.first?.line == 7)
        #expect(result.html.contains("<h2 id=\"after\" data-line=\"7\">"))
    }

    @Test func rendersMermaidAndMathCodeBlocks() {
        let result = render("```mermaid\ngraph TD\n  A-->B\n```\n\n```math\nE=mc^2\n```\n\n```swift\nlet x = 1\n```")
        #expect(result.html.contains("<div class=\"mermaid-block\" data-line=\"1\"><pre class=\"mermaid-source\">graph TD\n  A--&gt;B\n</pre></div>"))
        #expect(result.html.contains("<div class=\"math math-display\" data-line=\"6\">E=mc^2\n</div>"))
        #expect(result.html.contains("<code class=\"language-swift\">"))
    }

    @Test func extensionSyntaxInsideRawHTMLIsSanitizedAsSource() {
        let image = render("<img src=\"x.png\" alt=\"$\" onerror=\"alert(1)$\">").html
        #expect(!image.contains("onerror"))
        #expect(image.contains("<img src=\"x.png\" alt=\"$\">"))

        let div = render("<div [[a onmouseover=x style=position:fixed b]]>hi</div>").html
        #expect(!div.contains("onmouseover"))
        #expect(!div.contains("[["))
        #expect(div.contains("<div style=\"position:fixed\">hi</div>"))
    }

    @Test func extensionSyntaxInsideLinkDestinationStaysInsideAttribute() {
        let html = render("[x](http://a/[[b\"onmouseover=alert(1)]]) ![y](p.png \"$\" onload=\"x$\")").html
        #expect(html.contains("<a href=\"http://a/[[b&quot;onmouseover=alert(1)]]\">x</a>"))
        #expect(html.contains("title=\"$&quot; onload=&quot;x$\""))
        #expect(!html.contains("\"onmouseover"))
        #expect(!html.contains("\" onload"))
    }

    @Test func embedAliasIsEscapedAsAttribute() {
        let html = render("![[pic.png|a\" onerror=\"alert(1)]]").html
        #expect(html.contains("alt=\"a&quot; onerror=&quot;alert(1)\""))
    }

    @Test func privateUseCharactersDoNotCollideWithPlaceholders() {
        #expect(render("icon \u{E000} [[Note]]").html.contains("icon \u{E000} <a class=\"wikilink\" href=\"litemd-wiki:Note\">Note</a>"))
        #expect(render("\u{E000}0\u{E001} and [[Note]]").html.contains("<p data-line=\"1\">\u{E000}0\u{E001} and <a class=\"wikilink\""))
        #expect(render("a\u{E001}b $x$").html.contains("a\u{E001}b <span"))
        #expect(render("`\u{E000}1\u{E001}` [[x]]").html.contains("<code>\u{E000}1\u{E001}</code>"))
        #expect(!render("[[Note]]\u{0301} and $x$\u{0301}").html.contains("\u{E000}"))
    }

    @Test func restoresSourceInsideIndentedCodeAndRawHTML() {
        let result = render("    [[not rendered]] $x$\n\n<div>[[raw]]</div>")
        #expect(result.html.contains("[[not rendered]] $x$"))
        #expect(!result.html.contains("\u{E000}"))
    }
}

@Suite("Highlighter extensions")
struct HighlighterExtensionTests {
    let highlighter = MarkdownHighlighter()

    private func tokens(_ text: String, _ kind: HighlightKind) -> [String] {
        highlighter.tokens(in: text).filter { $0.kind == kind }.map { (text as NSString).substring(with: $0.range) }
    }

    @Test func wikiLinksAndAliases() {
        let text = "See [[Plan|the plan]] and ![[pic.png]] but not [link](x)."
        #expect(tokens(text, .wikiLink) == ["[[Plan|the plan]]", "![[pic.png]]"])
        #expect(tokens(text, .url).contains("Plan|"))
        #expect(tokens(text, .marker).contains("![["))
        #expect(tokens(text, .link) == ["[link](x)"])
    }

    @Test func inlineAndBlockMath() {
        let text = "Cost $5 and $10. Euler $e^{i\\pi}$.\n$$\nx^2\n$$\nafter"
        #expect(tokens(text, .math) == ["$e^{i\\pi}$", "$$", "x^2", "$$"])
    }
}

@Suite("Highlighter task boxes")
struct HighlighterTaskBoxTests {
    @Test func taskBoxesHaveTheirOwnKind() {
        let text = "- [ ] todo\n- [x] done"
        let boxes = MarkdownHighlighter().tokens(in: text).filter { $0.kind == .taskBox }.map { (text as NSString).substring(with: $0.range) }
        #expect(boxes == ["[ ]", "[x]"])
    }
}
