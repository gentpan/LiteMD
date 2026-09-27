import Foundation
@testable import LiteMDConversion
import Testing

/// 1×1 红色 PNG。
private let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")!

private final class TemporaryFolder {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("LiteMDConversion-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

@Suite("ZIP")
struct ZipTests {
    @Test func roundTripsStoredAndDeflatedEntries() throws {
        var writer = ZipWriter()
        let large = String(repeating: "LiteMD 中文 ", count: 500)
        writer.add("mimetype", string: "application/epub+zip", compress: false)
        writer.add("folder/large.txt", string: large)
        writer.add("binary.png", data: tinyPNG, compress: false)
        let archive = try ZipArchive(data: writer.finish())

        #expect(archive.orderedPaths == ["mimetype", "folder/large.txt", "binary.png"])
        #expect(try archive.data(for: "mimetype") == Data("application/epub+zip".utf8))
        #expect(try archive.data(for: "folder/large.txt") == Data(large.utf8))
        #expect(try archive.data(for: "/binary.png") == tinyPNG)
        #expect(ZipArchive.resolve("../media/a.png", relativeTo: "word/document.xml") == "media/a.png")
        #expect(ZipArchive.resolve("media/a.png", relativeTo: "word/document.xml") == "word/media/a.png")
    }

    @Test func rejectsNonArchives() {
        #expect(throws: ConversionError.self) {
            try ZipArchive(data: Data("not a zip".utf8))
        }
    }

    @Test func totalDecompressionIsBudgeted() throws {
        var writer = ZipWriter()
        for index in 0..<3 {
            writer.add("f\(index).txt", string: String(repeating: "a", count: 1000))
        }
        let archive = try ZipArchive(data: writer.finish(), maximumTotalSize: 2500)
        #expect(try archive.data(for: "f0.txt").count == 1000)
        #expect(try archive.data(for: "f1.txt").count == 1000)
        #expect(throws: ConversionError.self) { try archive.data(for: "f2.txt") }
    }

    @Test func declaredSizeIsNotTrusted() throws {
        var writer = ZipWriter()
        writer.add("fake.txt", string: String(repeating: "a", count: 1000))
        writer.add("real.txt", string: String(repeating: "b", count: 1000))
        var data = writer.finish()
        // 把第一条中央目录记录声明的解压大小改成 200 MB。
        let record = try #require(data.range(of: Data([0x50, 0x4B, 0x01, 0x02]))).lowerBound
        let declared = UInt32(200 * 1024 * 1024)
        for byte in 0..<4 {
            data[record + 24 + byte] = UInt8((declared >> (8 * UInt32(byte))) & 0xFF)
        }
        let archive = try ZipArchive(data: data, maximumTotalSize: Int(declared) + 500)
        #expect(throws: ConversionError.self) { try archive.data(for: "fake.txt") }
        // 失败的条目退回额度。
        #expect(try archive.data(for: "real.txt").count == 1000)
    }
}

@Suite("DOCX")
struct DocxTests {
    let markdown = """
    # 项目计划

    Some **bold**, *italic*, ~~old~~ and `code` with a [link](https://litemd.app).

    ## Tasks

    - First
    - Second
        - Nested

    1. One
    2. Two

    - [x] Done
    - [ ] Todo

    > Quote line

    ```swift
    let value = 1
    print(value)
    ```

    | Name | Value |
    | :--- | ---: |
    | LiteMD | 中文 |

    ![Logo](logo.png)
    """

    @Test func exportsWellFormedPackage() throws {
        let folder = TemporaryFolder()
        try tinyPNG.write(to: folder.url.appendingPathComponent("logo.png"))

        let data = try DocxExporter().export(markdown, options: ExportOptions(title: "Plan", documentDirectory: folder.url))
        let archive = try ZipArchive(data: data)

        for part in ["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/styles.xml", "word/numbering.xml", "word/_rels/document.xml.rels", "docProps/core.xml"] {
            let xml = try archive.data(for: part)
            #expect(throws: Never.self) { try XMLTree.parse(xml) }
        }
        #expect(archive.contains("word/media/image1.png"))

        let document = String(decoding: try archive.data(for: "word/document.xml"), as: UTF8.self)
        #expect(document.contains("<w:pStyle w:val=\"Heading1\"/>"))
        #expect(document.contains("<w:numPr><w:ilvl w:val=\"1\"/>"))
        #expect(document.contains("<w:rStyle w:val=\"VerbatimChar\"/>"))
        #expect(document.contains("<w:hyperlink r:id="))
        #expect(document.contains("<w:tbl>"))
    }

    @Test func nestedOrderedListKeepsStartNumber() throws {
        let data = try DocxExporter().export("1. a\n\n   3. x\n", options: ExportOptions(title: "Lists"))
        let numbering = String(decoding: try ZipArchive(data: data).data(for: "word/numbering.xml"), as: UTF8.self)
        #expect(numbering.contains("<w:lvlOverride w:ilvl=\"1\"><w:startOverride w:val=\"3\"/></w:lvlOverride>"))
        #expect(numbering.contains("<w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride>"))
    }

    @Test func rendersExtensionsAndDropsControlCharacters() throws {
        let data = try DocxExporter().export("[[Note|Alias]] and $x_1^2$ a\u{0C}b", options: ExportOptions(title: "T\u{01}"))
        let archive = try ZipArchive(data: data)
        let document = String(decoding: try archive.data(for: "word/document.xml"), as: UTF8.self)
        #expect(document.contains("<w:t xml:space=\"preserve\">Alias</w:t>"))
        #expect(document.contains("<w:rStyle w:val=\"VerbatimChar\"/></w:rPr><w:t xml:space=\"preserve\">x_1^2</w:t>"))
        #expect(!document.contains("[[Note"))
        #expect(!document.contains("\u{0C}"))
        for part in ["word/document.xml", "docProps/core.xml"] {
            #expect(throws: Never.self) { try XMLTree.parse(try archive.data(for: part)) }
        }
    }

    @Test func roundTripsThroughImporter() throws {
        let folder = TemporaryFolder()
        try tinyPNG.write(to: folder.url.appendingPathComponent("logo.png"))
        let data = try DocxExporter().export(markdown, options: ExportOptions(title: "Plan", documentDirectory: folder.url))

        let result = try DocxImporter().convert(data, options: ImportOptions(assetDirectory: "assets", assetPrefix: "plan"))
        let output = result.markdown
        #expect(output.contains("# 项目计划"))
        #expect(output.contains("## Tasks"))
        #expect(output.contains("**bold**"))
        #expect(output.contains("*italic*"))
        #expect(output.contains("~~old~~"))
        #expect(output.contains("`code`"))
        #expect(output.contains("[link](https://litemd.app)"))
        #expect(output.contains("- First\n- Second\n    - Nested"))
        #expect(output.contains("- Nested\n\n1. One\n1. Two"))
        #expect(output.contains("- [x] Done\n- [ ] Todo"))
        #expect(output.contains("> Quote line"))
        #expect(output.contains("```\nlet value = 1\nprint(value)\n```"))
        #expect(output.contains("| Name | Value |"))
        #expect(output.contains("| LiteMD | 中文 |"))
        #expect(output.contains("![Logo](assets/plan-1.png)"))
        #expect(result.assets == [ConvertedAsset(fileName: "plan-1.png", data: tinyPNG)])
        #expect(result.title == "Plan")
    }

    @Test func importsPandocGeneratedDocument() throws {
        let url = try #require(Bundle.module.url(forResource: "pandoc-sample", withExtension: "docx", subdirectory: "Fixtures"))
        let result = try DocxImporter().convert(try Data(contentsOf: url))
        #expect(result.markdown.contains("# LiteMD"))
        #expect(result.markdown.contains("## Features"))
        #expect(result.markdown.contains("**Local-first**"))
        #expect(result.markdown.contains("| Name | Value |"))
        #expect(result.markdown.contains("> Markdown File = Source of Truth"))
        #expect(result.assets.count == 1)
    }
}

@Suite("Office importers")
struct OfficeImporterTests {
    @Test func importsSpreadsheetSheetsAsTables() throws {
        var writer = ZipWriter()
        writer.add("xl/workbook.xml", string: """
        <workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="预算" sheetId="1" r:id="rId1"/></sheets></workbook>
        """)
        writer.add("xl/_rels/workbook.xml.rels", string: """
        <Relationships><Relationship Id="rId1" Type="worksheet" Target="worksheets/sheet1.xml"/></Relationships>
        """)
        writer.add("xl/sharedStrings.xml", string: "<sst><si><t>Item</t></si><si><t>Cost</t></si><si><r><t>Coffee</t></r><r><t> beans</t></r></si></sst>")
        writer.add("xl/worksheets/sheet1.xml", string: """
        <worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row><row r="2"><c r="A2" t="s"><v>2</v></c><c r="C2"><v>12.5</v></c></row></sheetData></worksheet>
        """)

        let result = try XlsxImporter().convert(writer.finish())
        #expect(result.markdown == "## 预算\n\n| Item | Cost |  |\n| --- | --- | --- |\n| Coffee beans |  | 12.5 |\n")
        #expect(XlsxImporter.columnIndex("AB12") == 27)
    }

    @Test func spreadsheetCellReferencesAndGridAreBounded() throws {
        #expect(XlsxImporter.columnIndex("XFD1") == 16_383)
        #expect(XlsxImporter.columnIndex("XFE1") == nil)
        #expect(XlsxImporter.columnIndex("ZZZZZZZZZZZZZZ1") == nil)
        #expect(XlsxImporter.columnIndex("12") == nil)

        let sheet = try XMLTree.parse(Data("""
        <worksheet><sheetData><row r="1"><c r="A1"><v>1</v></c><c r="ZZZZZZZZZZZZZZ1"><v>bad</v></c></row><row r="1048576"><c r="XFD1048576"><v>2</v></c></row></sheetData></worksheet>
        """.utf8))
        let table = XlsxImporter.rows(in: sheet, sharedStrings: [])
        #expect(table.isTruncated)
        #expect(table.rows.first?.first == "1")
        #expect(table.rows.count * (table.rows.first?.count ?? 0) <= XlsxImporter.importedCellLimit)
        #expect(!table.rows.joined().contains("bad"))
    }

    @Test func spreadsheetTextSkipsPhoneticRuns() throws {
        let strings = try XMLTree.parse(Data("""
        <sst><si><t>東京</t><rPh sb="0" eb="2"><t>トウキョウ</t></rPh></si><si><r><t>大</t></r><r><t>阪</t></r><rPh sb="0" eb="2"><t>オオサカ</t></rPh></si></sst>
        """.utf8))
        #expect(strings.children("si").map(XlsxImporter.richText) == ["東京", "大阪"])

        let sheet = try XMLTree.parse(Data("""
        <worksheet><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>京都</t><rPh><t>キョウト</t></rPh></is></c></row></sheetData></worksheet>
        """.utf8))
        #expect(XlsxImporter.rows(in: sheet, sharedStrings: []).rows == [["京都"]])
    }

    @Test func importsSlidesWithTitlesBulletsAndNotes() throws {
        var writer = ZipWriter()
        writer.add("ppt/presentation.xml", string: """
        <p:presentation xmlns:p="p" xmlns:r="r"><p:sldIdLst><p:sldId id="256" r:id="rId2"/></p:sldIdLst></p:presentation>
        """)
        writer.add("ppt/_rels/presentation.xml.rels", string: "<Relationships><Relationship Id=\"rId2\" Type=\"slide\" Target=\"slides/slide1.xml\"/></Relationships>")
        writer.add("ppt/slides/slide1.xml", string: """
        <p:sld xmlns:p="p" xmlns:a="a"><p:cSld><p:spTree>
        <p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>Roadmap</a:t></a:r></a:p></p:txBody></p:sp>
        <p:sp><p:nvSpPr><p:nvPr><p:ph type="body"/></p:nvPr></p:nvSpPr><p:txBody>
        <a:p><a:r><a:rPr b="1"/><a:t>Native</a:t></a:r><a:r><a:t> apps</a:t></a:r></a:p>
        <a:p><a:pPr lvl="1"/><a:r><a:t>macOS first</a:t></a:r></a:p>
        </p:txBody></p:sp>
        </p:spTree></p:cSld></p:sld>
        """)
        writer.add("ppt/slides/_rels/slide1.xml.rels", string: "<Relationships><Relationship Id=\"rId9\" Type=\"http://x/notesSlide\" Target=\"../notesSlides/notesSlide1.xml\"/></Relationships>")
        writer.add("ppt/notesSlides/notesSlide1.xml", string: """
        <p:notes xmlns:p="p" xmlns:a="a"><p:cSld><p:spTree><p:sp><p:nvSpPr><p:nvPr><p:ph type="body"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>Mention iOS</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:notes>
        """)

        let result = try PptxImporter().convert(writer.finish())
        #expect(result.markdown == "## Roadmap\n\n- **Native** apps\n    - macOS first\n\n> Mention iOS\n")
    }
}

@Suite("HTML, EPUB, CSV, LaTeX")
struct WebAndTextConversionTests {
    @Test func convertsMessyHTML() throws {
        let html = """
        <html><head><title>Notes</title><script>alert(1)</script></head>
        <body><h1>Hello &amp; welcome</h1>
        <p>Some <b>bold</b> and <a href="https://litemd.app">a link</a><br>next line
        <p>Second paragraph with <code>x < y</code>
        <ul><li>One<li>Two <em>em</em></ul>
        <table><tr><th>A<th>B</tr><tr><td>1<td>2</tr></table>
        <pre><code class="language-swift">let a = 1</code></pre>
        <img src="pic.png" alt="Pic">
        </body></html>
        """
        let result = try DocumentImporter().convert(Data(html.utf8), fileName: "page.html", options: ImportOptions())
        #expect(result.title == "Notes")
        #expect(result.markdown.contains("# Hello & welcome"))
        #expect(result.markdown.contains("Some **bold** and [a link](https://litemd.app)<br>next line"))
        #expect(result.markdown.contains("Second paragraph with `x < y`"))
        #expect(result.markdown.contains("- One\n- Two *em*"))
        #expect(result.markdown.contains("| A | B |"))
        #expect(result.markdown.contains("```swift\nlet a = 1\n```"))
        #expect(result.markdown.contains("![Pic](pic.png)"))
        #expect(!result.markdown.contains("alert"))
    }

    @Test func epubRoundTripKeepsStructureAndImages() throws {
        let folder = TemporaryFolder()
        try tinyPNG.write(to: folder.url.appendingPathComponent("logo.png"))
        let markdown = "# Book\n\nIntro **text**.\n\n## Chapter\n\n- item\n\n![Logo](logo.png)\n\n<div>raw</div>\n"

        let data = try EpubExporter().export(markdown, options: ExportOptions(title: "My Book", documentDirectory: folder.url, language: "zh-Hans"), stylesheet: "body{}")
        let archive = try ZipArchive(data: data)
        #expect(archive.orderedPaths.first == "mimetype")
        for part in ["OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/chapter.xhtml", "META-INF/container.xml"] {
            #expect(throws: Never.self) { try XMLTree.parse(try archive.data(for: part)) }
        }

        let result = try EpubImporter().convert(data, options: ImportOptions(assetPrefix: "book"))
        #expect(result.title == "My Book")
        #expect(result.markdown.contains("## Chapter"))
        #expect(result.markdown.contains("Intro **text**."))
        #expect(result.markdown.contains("![Logo](assets/book-1.png)"))
        #expect(result.assets.count == 1)
    }

    @Test func htmlAttributeValuesMayContainGreaterThan() throws {
        let html = "<p><img alt=\"a > b\" src=\"p.png\"> after</p>"
        let result = try DocumentImporter().convert(Data(html.utf8), fileName: "page.html", options: ImportOptions())
        #expect(result.markdown == "![a > b](p.png) after\n")
    }

    @Test func decodesGB18030InsteadOfGuessingUTF16() throws {
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let text = try #require("你好，世界".data(using: gb18030))
        #expect(try DocumentImporter().convert(text, fileName: "a.txt", options: ImportOptions()).markdown == "你好，世界")
        let csv = try #require("名称,数量\n苹果,3\n".data(using: gb18030))
        #expect(try DocumentImporter().convert(csv, fileName: "a.csv", options: ImportOptions()).markdown.contains("| 苹果 | 3 |"))

        #expect(DocumentImporter.decode(try #require("hello, 世界".data(using: .utf16))) == "hello, 世界")
        #expect(DocumentImporter.decode(try #require("plain ascii".data(using: .utf16LittleEndian))) == "plain ascii")
        #expect(DocumentImporter.decode(try #require("plain ascii".data(using: .utf16BigEndian))) == "plain ascii")
        #expect(DocumentImporter.decode(Data([0xEF, 0xBB, 0xBF]) + Data("abc".utf8)) == "abc")
    }

    @Test func escapesParenthesisListsAndTildeFences() throws {
        #expect(MarkdownComposer.escapeLineStart("1) item") == "1\\) item")
        #expect(MarkdownComposer.escapeLineStart("12. item") == "12\\. item")
        #expect(MarkdownComposer.escapeLineStart("~~~ code") == "\\~~~ code")
        let html = "<p>~~~</p><p>1) after</p><p>tail</p>"
        let result = try DocumentImporter().convert(Data(html.utf8), fileName: "page.html", options: ImportOptions())
        #expect(result.markdown == "\\~~~\n\n1\\) after\n\ntail\n")
    }

    @Test func csvHandlesQuotesAndDelimiters() throws {
        let csv = "name,note\n\"LiteMD, app\",\"say \"\"hi\"\"\"\nplain,\"multi\nline\"\n"
        let result = try CsvImporter().convert(csv)
        #expect(result.markdown == "| name | note |\n| --- | --- |\n| LiteMD, app | say \"hi\" |\n| plain | multi<br>line |\n")
        #expect(CsvImporter.detectDelimiter("a;b;c\n1;2;3") == ";")
    }

    @Test func epubPackagesImagesStructurally() throws {
        let folder = TemporaryFolder()
        try tinyPNG.write(to: folder.url.appendingPathComponent("logo.png"))
        try tinyPNG.write(to: folder.url.appendingPathComponent("it's.png"))
        try tinyPNG.write(to: folder.url.appendingPathComponent("absolute.png"))
        let absolute = folder.url.appendingPathComponent("absolute.png").absoluteString
        let markdown = """
        ![a](logo.png) ![b](logo.png) ![c](it's.png) ![d](\(absolute)) ![[logo.png]]

        ```html
        <img src="logo.png">
        ```
        """
        let data = try EpubExporter().export(markdown, options: ExportOptions(title: "Images", documentDirectory: folder.url), stylesheet: "")
        let archive = try ZipArchive(data: data)
        let chapter = String(decoding: try archive.data(for: "OEBPS/chapter.xhtml"), as: UTF8.self)
        #expect(chapter.contains("<code class=\"language-html\">&lt;img src=\"logo.png\"&gt;"))
        #expect(chapter.contains("<img src=\"images/image1.png\" alt=\"a\"/> <img src=\"images/image1.png\" alt=\"b\"/>"))
        #expect(chapter.contains("<img src=\"images/image2.png\" alt=\"c\"/>"))
        #expect(chapter.contains("<img src=\"images/image3.png\" alt=\"d\"/>"))
        #expect(chapter.contains("<img class=\"wikilink-embed\" src=\"images/image1.png\""))
        #expect(archive.orderedPaths.filter { $0.hasPrefix("OEBPS/images/") }.count == 3)
    }

    @Test func epubTableOfContentsMatchesBodyAndStaysValidXML() throws {
        let markdown = "# Intro [[Note|Alias]]\n\n## Math $x_1$\n\na\u{0C}b \u{FFFE}\n"
        let data = try EpubExporter().export(markdown, options: ExportOptions(title: "Book"), stylesheet: "")
        let archive = try ZipArchive(data: data)
        let navigation = String(decoding: try archive.data(for: "OEBPS/nav.xhtml"), as: UTF8.self)
        let chapter = String(decoding: try archive.data(for: "OEBPS/chapter.xhtml"), as: UTF8.self)
        #expect(navigation.contains("<a href=\"chapter.xhtml#intro-alias\">Intro Alias</a>"))
        #expect(chapter.contains("<h1 id=\"intro-alias\">"))
        #expect(navigation.contains("<a href=\"chapter.xhtml#math-x_1\">Math $x_1$</a>"))
        #expect(chapter.contains("<h2 id=\"math-x_1\">"))
        for part in ["OEBPS/nav.xhtml", "OEBPS/chapter.xhtml"] {
            #expect(throws: Never.self) { try XMLTree.parse(try archive.data(for: part)) }
        }
    }

    @Test func latexHandlesListStartsNestingAndPackages() {
        let latex = LatexExporter().export("0. zero\n\n1. a\n\n   3. b\n\n- [ ] todo\n\na < b > c\n", options: ExportOptions(title: "T"))
        #expect(latex.contains("\\begin{enumerate}\n\\setcounter{enumi}{-1}\n\\item zero"))
        #expect(latex.contains("\\setcounter{enumii}{2}\n\\item b"))
        #expect(!latex.contains("\\setcounter{enumi}{2}"))
        #expect(latex.contains("\\usepackage{amssymb}"))
        #expect(latex.contains("\\usepackage[T1]{fontenc}"))
        #expect(latex.contains("\\item[$\\square$] todo"))
    }

    @Test func latexKeepsMathAndGuardsImagePaths() {
        let markdown = "Inline $x_1$ and $\\{1,2\\}$, [[Note|Alias]].\n\n$$\\frac{1}{2}$$\n\n![photo](my%20photo.png) ![pct](a%25b.png) ![web](https://x.y/a.png)\n"
        let latex = LatexExporter().export(markdown, options: ExportOptions(title: "T"))
        #expect(latex.contains("Inline $x_1$ and $\\{1,2\\}$, Alias."))
        #expect(latex.contains("\\[\\frac{1}{2}\\]"))
        #expect(latex.contains("\\includegraphics[width=0.8\\linewidth]{my photo.png}"))
        #expect(!latex.contains("a%b.png"))
        #expect(latex.contains("pct"))
        #expect(latex.contains("web"))
    }

    @Test func latexEscapesAndUsesCtexForChinese() {
        let latex = LatexExporter().export("# 标题\n\n100% of $5 & **bold** `a_b`\n\n- [x] done\n", options: ExportOptions(title: "T_1"))
        #expect(latex.contains("\\documentclass[11pt]{ctexart}"))
        #expect(latex.contains("\\section{标题}"))
        #expect(latex.contains("100\\% of \\$5 \\& \\textbf{bold} \\texttt{a\\_b}"))
        #expect(latex.contains("\\item[$\\boxtimes$] done"))
        #expect(latex.contains("\\title{T\\_1}"))
    }
}
