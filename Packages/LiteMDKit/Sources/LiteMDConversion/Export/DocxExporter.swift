import Foundation
import ImageIO
import LiteMDMarkdown
import Markdown

public struct ExportOptions: Sendable {
    public var title: String
    /// 用于解析 Markdown 中的相对图片路径。
    public var documentDirectory: URL?
    /// BCP 47 语言标签，例如 `zh-Hans`。
    public var language: String

    public init(title: String, documentDirectory: URL? = nil, language: String = "en") {
        self.title = title
        self.documentDirectory = documentDirectory
        self.language = language
    }
}

/// Markdown → Word（.docx）。
///
/// 使用 Word 内置样式名（Heading 1–6、Quote、List Paragraph 等），
/// 在 Word 中可以直接生成目录、切换样式；列表使用真正的编号定义而不是文字前缀。
public struct DocxExporter: Sendable {
    public init() {}

    public func export(_ markdown: String, options: ExportOptions) throws(ConversionError) -> Data {
        let parsed = ExtendedMarkdownDocument(parsing: markdown)
        var builder = DocxBuilder(options: options, parsed: parsed)
        builder.visit(parsed.document)

        var archive = ZipWriter()
        archive.add("[Content_Types].xml", string: builder.contentTypes())
        archive.add("_rels/.rels", string: DocxParts.packageRelationships)
        archive.add("docProps/core.xml", string: DocxParts.coreProperties(title: options.title))
        archive.add("word/document.xml", string: builder.documentXML())
        archive.add("word/styles.xml", string: DocxParts.styles)
        archive.add("word/numbering.xml", string: builder.numberingXML())
        archive.add("word/_rels/document.xml.rels", string: builder.relationshipsXML())
        for medium in builder.media {
            archive.add("word/\(medium.path)", data: medium.data, compress: false)
        }
        return archive.finish()
    }
}

private struct DocxBuilder: MarkupVisitor {
    typealias Result = Void

    struct RunStyle {
        var bold = false
        var italic = false
        var strikethrough = false
        var code = false
        var link = false
    }

    struct Medium {
        var path: String
        var data: Data
        var fileExtension: String
    }

    let options: ExportOptions
    let parsed: ExtendedMarkdownDocument
    private var body = ""
    private var runs = ""
    private var style = RunStyle()
    private var relationships: [(id: String, type: String, target: String, external: Bool)] = []
    private(set) var media: [Medium] = []
    /// 每个有序列表一个编号实例；嵌套列表的起始编号要写在它实际使用的层级上。
    private var orderedLists: [(numID: Int, start: Int, level: Int)] = []
    private var listStack: [Int] = []
    private var pendingNumbering: (numID: Int, level: Int)?
    private var pendingPrefix = ""
    private var quoteDepth = 0
    private var drawingID = 0
    private var inTableHeader = false

    /// Word 的编号定义只有 0–8 九级。
    static let maximumListLevel = 8

    init(options: ExportOptions, parsed: ExtendedMarkdownDocument) {
        self.options = options
        self.parsed = parsed
        relationships = [
            ("rIdStyles", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles", "styles.xml", false),
            ("rIdNumbering", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering", "numbering.xml", false),
        ]
    }

    // MARK: Output

    func documentXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr></w:body></w:document>
        """
    }

    func relationshipsXML() -> String {
        let items = relationships.map { relationship in
            let mode = relationship.external ? " TargetMode=\"External\"" : ""
            return "<Relationship Id=\"\(relationship.id)\" Type=\"\(relationship.type)\" Target=\"\(XMLTree.escape(relationship.target))\"\(mode)/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(items)</Relationships>
        """
    }

    func contentTypes() -> String {
        var defaults: [String: String] = [
            "rels": "application/vnd.openxmlformats-package.relationships+xml",
            "xml": "application/xml",
        ]
        for medium in media {
            defaults[medium.fileExtension] = DocxParts.mimeType(for: medium.fileExtension)
        }
        let defaultXML = defaults.sorted { $0.key < $1.key }.map { "<Default Extension=\"\($0.key)\" ContentType=\"\($0.value)\"/>" }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\(defaultXML)<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>
        """
    }

    func numberingXML() -> String {
        let bulletSymbols = ["•", "◦", "▪"]
        let bulletLevels = (0..<9).map { level in
            "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"\(bulletSymbols[level % 3])\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(720 * (level + 1))\" w:hanging=\"360\"/></w:pPr></w:lvl>"
        }.joined()
        let decimalFormats = ["decimal", "lowerLetter", "lowerRoman"]
        let decimalLevels = (0..<9).map { level in
            "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(decimalFormats[level % 3])\"/><w:lvlText w:val=\"%\(level + 1).\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(720 * (level + 1))\" w:hanging=\"360\"/></w:pPr></w:lvl>"
        }.joined()
        let instances = orderedLists.map { list in
            "<w:num w:numId=\"\(list.numID)\"><w:abstractNumId w:val=\"2\"/><w:lvlOverride w:ilvl=\"\(list.level)\"><w:startOverride w:val=\"\(list.start)\"/></w:lvlOverride></w:num>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/>\(bulletLevels)</w:abstractNum><w:abstractNum w:abstractNumId="2"><w:multiLevelType w:val="hybridMultilevel"/>\(decimalLevels)</w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="1"/></w:num>\(instances)</w:numbering>
        """
    }

    // MARK: Helpers

    private mutating func paragraph(style paragraphStyle: String?, extra: String = "", _ content: (inout DocxBuilder) -> Void) {
        let savedRuns = runs
        runs = ""
        if !pendingPrefix.isEmpty {
            appendText(pendingPrefix)
            pendingPrefix = ""
        }
        content(&self)

        var properties = ""
        var styleName = paragraphStyle
        if styleName == nil, quoteDepth > 0 { styleName = "Quote" }
        if let numbering = pendingNumbering {
            styleName = styleName ?? "ListParagraph"
            properties += "<w:numPr><w:ilvl w:val=\"\(numbering.level)\"/><w:numId w:val=\"\(numbering.numID)\"/></w:numPr>"
            pendingNumbering = nil
        } else if !listStack.isEmpty, paragraphStyle == nil {
            // 列表项中的后续段落：缩进对齐，不带编号。
            styleName = "ListParagraph"
            properties += "<w:ind w:left=\"\(720 * listStack.count)\"/>"
        }
        let styleXML = styleName.map { "<w:pStyle w:val=\"\($0)\"/>" } ?? ""
        body += "<w:p><w:pPr>\(styleXML)\(properties)\(extra)</w:pPr>\(runs)</w:p>"
        runs = savedRuns
    }

    private mutating func appendText(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if index > 0 { runs += "<w:r><w:br/></w:r>" }
            guard !line.isEmpty else { continue }
            runs += "<w:r>\(runProperties())<w:t xml:space=\"preserve\">\(XMLTree.escape(line))</w:t></w:r>"
        }
    }

    private func runProperties() -> String {
        var properties = ""
        if style.code { properties += "<w:rStyle w:val=\"VerbatimChar\"/>" }
        if style.link { properties += "<w:rStyle w:val=\"Hyperlink\"/>" }
        if style.bold || inTableHeader { properties += "<w:b/>" }
        if style.italic { properties += "<w:i/>" }
        if style.strikethrough { properties += "<w:strike/>" }
        return properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>"
    }

    private mutating func addRelationship(type: String, target: String, external: Bool) -> String {
        let id = "rId\(relationships.count + 1)"
        relationships.append((id, type, target, external))
        return id
    }

    // MARK: Blocks

    mutating func defaultVisit(_ markup: any Markup) {
        for child in markup.children {
            visit(child)
        }
    }

    mutating func visitHeading(_ heading: Heading) {
        paragraph(style: "Heading\(min(heading.level, 6))") { builder in
            builder.defaultVisit(heading)
        }
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        self.paragraph(style: nil) { builder in
            builder.defaultVisit(paragraph)
        }
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        quoteDepth += 1
        defaultVisit(blockQuote)
        quoteDepth -= 1
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        var code = parsed.source(of: codeBlock.code)
        while code.hasSuffix("\n") { code.removeLast() }
        paragraph(style: "SourceCode") { builder in
            builder.appendText(code)
        }
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        paragraph(style: nil, extra: "<w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"D1D5DB\"/></w:pBdr>") { _ in }
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        // 原始 HTML 不适合放进 Word，保留为可见文本。
        let text = parsed.source(of: html.rawHTML).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        paragraph(style: nil) { builder in builder.appendText(text) }
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        listStack.append(1)
        defaultVisit(unorderedList)
        listStack.removeLast()
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        let numID = 2 + orderedLists.count
        orderedLists.append((numID, Int(orderedList.startIndex), min(listStack.count, Self.maximumListLevel)))
        listStack.append(numID)
        defaultVisit(orderedList)
        listStack.removeLast()
    }

    mutating func visitListItem(_ listItem: ListItem) {
        pendingNumbering = (listStack.last ?? 1, min(max(0, listStack.count - 1), Self.maximumListLevel))
        switch listItem.checkbox {
        case .checked: pendingPrefix = "☒ "
        case .unchecked: pendingPrefix = "☐ "
        case nil: pendingPrefix = ""
        }
        defaultVisit(listItem)
        pendingNumbering = nil
        pendingPrefix = ""
    }

    mutating func visitTable(_ table: Table) {
        let alignments = table.columnAlignments
        let columns = max(table.maxColumnCount, 1)
        let grid = String(repeating: "<w:gridCol w:w=\"\(9000 / columns)\"/>", count: columns)
        body += "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"5000\" w:type=\"pct\"/></w:tblPr><w:tblGrid>\(grid)</w:tblGrid>"

        func row(_ cells: [Table.Cell], header: Bool, builder: inout DocxBuilder) {
            builder.body += header ? "<w:tr><w:trPr><w:tblHeader/></w:trPr>" : "<w:tr>"
            for (column, cell) in cells.enumerated() {
                let alignment: String
                switch column < alignments.count ? alignments[column] : nil {
                case .center: alignment = "<w:jc w:val=\"center\"/>"
                case .right: alignment = "<w:jc w:val=\"right\"/>"
                default: alignment = ""
                }
                builder.body += "<w:tc><w:tcPr><w:tcW w:w=\"0\" w:type=\"auto\"/></w:tcPr>"
                builder.inTableHeader = header
                builder.paragraph(style: "Compact", extra: alignment) { inner in
                    inner.defaultVisit(cell)
                }
                builder.inTableHeader = false
                builder.body += "</w:tc>"
            }
            builder.body += "</w:tr>"
        }

        row(Array(table.head.cells), header: true, builder: &self)
        for bodyRow in table.body.rows {
            row(Array(bodyRow.cells), header: false, builder: &self)
        }
        body += "</w:tbl><w:p/>"
    }

    // MARK: Inlines

    mutating func visitText(_ text: Markdown.Text) {
        for segment in parsed.segments(of: text.string) {
            switch segment {
            case .text(let string):
                appendText(string)
            case .wikiLink(let link):
                appendText(link.displayText)
            case .math(let math):
                // Word 的公式格式（OMML）与 TeX 不通用，保留源码，用等宽字体标出。
                let saved = style
                style.code = true
                appendText(math.tex)
                style = saved
            }
        }
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        appendText(" ")
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        runs += "<w:r><w:br/></w:r>"
    }

    mutating func visitStrong(_ strong: Strong) {
        let saved = style
        style.bold = true
        defaultVisit(strong)
        style = saved
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        let saved = style
        style.italic = true
        defaultVisit(emphasis)
        style = saved
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        let saved = style
        style.strikethrough = true
        defaultVisit(strikethrough)
        style = saved
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        let saved = style
        style.code = true
        appendText(parsed.source(of: inlineCode.code))
        style = saved
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {}

    mutating func visitLink(_ link: Markdown.Link) {
        guard let destination = link.destination.map(parsed.source), !destination.isEmpty, !destination.hasPrefix("#") else {
            defaultVisit(link)
            return
        }
        let id = addRelationship(
            type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink",
            target: destination,
            external: true
        )
        let saved = style
        let savedRuns = runs
        runs = ""
        style.link = true
        defaultVisit(link)
        style = saved
        runs = savedRuns + "<w:hyperlink r:id=\"\(id)\">\(runs)</w:hyperlink>"
    }

    mutating func visitImage(_ image: Markdown.Image) {
        let loader = LocalImageLoader(documentDirectory: options.documentDirectory)
        guard let (_, data, fileExtension) = loader.load(parsed.source(of: image.source ?? ""), allowedExtensions: Self.imageExtensions) else {
            appendText(parsed.plainText(of: image.plainText))
            return
        }
        let size = Self.pixelSize(of: data)
        let maximumWidth = 5_486_400.0 // 6 英寸
        var width = Double(size.width) * 9525
        var height = Double(size.height) * 9525
        if width > maximumWidth {
            height *= maximumWidth / width
            width = maximumWidth
        }

        let path = "media/image\(media.count + 1).\(fileExtension)"
        media.append(Medium(path: path, data: data, fileExtension: fileExtension))
        let id = addRelationship(type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", target: path, external: false)
        drawingID += 1
        let description = XMLTree.escape(parsed.plainText(of: image.plainText))
        let cx = Int(width)
        let cy = Int(height)
        runs += "<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/><wp:docPr id=\"\(drawingID)\" name=\"Picture \(drawingID)\" descr=\"\(description)\"/><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic><pic:nvPicPr><pic:cNvPr id=\"\(drawingID)\" name=\"image\(drawingID).\(fileExtension)\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"\(id)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"
    }

    /// Word 能直接显示的图片格式。
    static let imageExtensions: Set<String> = ["png", "jpg", "gif", "bmp", "tiff", "tif"]

    static func pixelSize(of data: Data) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return (400, 300)
        }
        return (width, height)
    }
}

enum DocxParts {
    static let packageRelationships = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>
    """

    static func coreProperties(title: String) -> String {
        let formatter = ISO8601DateFormatter()
        let now = formatter.string(from: Date())
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\(XMLTree.escape(title))</dc:title><dc:creator>LiteMD</dc:creator><dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified></cp:coreProperties>
        """
    }

    static func mimeType(for fileExtension: String) -> String {
        switch fileExtension {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "bmp": "image/bmp"
        case "tif", "tiff": "image/tiff"
        default: "application/octet-stream"
        }
    }

    private static func heading(_ level: Int, size: Int) -> String {
        "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(level)\"><w:name w:val=\"heading \(level)\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:uiPriority w:val=\"9\"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before=\"\(level <= 2 ? 360 : 240)\" w:after=\"120\"/><w:outlineLvl w:val=\"\(level - 1)\"/></w:pPr><w:rPr><w:b/><w:color w:val=\"111827\"/><w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/></w:rPr></w:style>"
    }

    static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="PingFang SC" w:cs="Calibri"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US" w:eastAsia="zh-CN"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="300" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/><w:rPr><w:color w:val="111827"/></w:rPr></w:style>\(heading(1, size: 36))\(heading(2, size: 32))\(heading(3, size: 28))\(heading(4, size: 24))\(heading(5, size: 22))\(heading(6, size: 22))<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:qFormat/><w:rPr><w:b/><w:sz w:val="48"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:pBdr><w:left w:val="single" w:sz="18" w:space="8" w:color="D1D5DB"/></w:pBdr><w:ind w:left="360"/></w:pPr><w:rPr><w:color w:val="6B7280"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="60"/><w:contextualSpacing/></w:pPr></w:style><w:style w:type="paragraph" w:styleId="Compact"><w:name w:val="Compact"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:before="40" w:after="40"/></w:pPr></w:style><w:style w:type="paragraph" w:styleId="SourceCode"><w:name w:val="Source Code"/><w:basedOn w:val="Normal"/><w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F3F4F6"/><w:spacing w:after="160" w:line="260" w:lineRule="auto"/></w:pPr><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:cs="Consolas"/><w:sz w:val="20"/></w:rPr></w:style><w:style w:type="character" w:styleId="VerbatimChar"><w:name w:val="Verbatim Char"/><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:cs="Consolas"/><w:sz w:val="20"/><w:shd w:val="clear" w:color="auto" w:fill="F3F4F6"/></w:rPr></w:style><w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:rPr><w:color w:val="2563EB"/><w:u w:val="single"/></w:rPr></w:style><w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="E5E7EB"/><w:left w:val="single" w:sz="4" w:space="0" w:color="E5E7EB"/><w:bottom w:val="single" w:sz="4" w:space="0" w:color="E5E7EB"/><w:right w:val="single" w:sz="4" w:space="0" w:color="E5E7EB"/><w:insideH w:val="single" w:sz="4" w:space="0" w:color="E5E7EB"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="E5E7EB"/></w:tblBorders><w:tblCellMar><w:left w:w="108" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style></w:styles>
    """
}
