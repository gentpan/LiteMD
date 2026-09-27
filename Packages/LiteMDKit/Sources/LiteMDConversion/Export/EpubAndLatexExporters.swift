import Foundation
import LiteMDMarkdown
import Markdown

/// Markdown → EPUB 3。单章节，目录由一、二级标题生成，本地图片打包进电子书。
public struct EpubExporter: Sendable {
    public init() {}

    public func export(_ markdown: String, options: ExportOptions, stylesheet: String) throws(ConversionError) -> Data {
        // 正文与目录出自同一次渲染，目录锚点才能与正文 id 对上。
        let fragment = MarkdownParser().xhtmlFragment(from: markdown)
        var body = fragment.html
        let headings = fragment.headings

        var images: [(path: String, data: Data, mediaType: String)] = []
        body = Self.rewriteImages(in: body, options: options, images: &images)

        let identifier = "urn:uuid:\(UUID().uuidString)"
        let modified = ISO8601DateFormatter().string(from: Date())
        let title = XMLTree.escape(options.title)
        let language = XMLTree.escape(options.language)

        let imageManifest = images.enumerated().map { index, image in
            "<item id=\"image\(index + 1)\" href=\"\(image.path)\" media-type=\"\(image.mediaType)\"/>"
        }.joined(separator: "\n    ")

        let package = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id" xml:lang="\(language)">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="book-id">\(identifier)</dc:identifier>
            <dc:title>\(title)</dc:title>
            <dc:language>\(language)</dc:language>
            <meta property="dcterms:modified">\(modified.prefix(19))Z</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
            <item id="style" href="style.css" media-type="text/css"/>
            \(imageManifest)
          </manifest>
          <spine>
            <itemref idref="chapter"/>
          </spine>
        </package>
        """

        let tocEntries = headings.filter { $0.level <= 2 }.map { heading in
            "<li><a href=\"chapter.xhtml#\(XMLTree.escape(heading.anchor))\">\(XMLTree.escape(heading.title))</a></li>"
        }
        let navigation = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(language)">
        <head><title>\(title)</title></head>
        <body><nav epub:type="toc" id="toc"><ol>\(tocEntries.isEmpty ? "<li><a href=\"chapter.xhtml\">\(title)</a></li>" : tocEntries.joined())</ol></nav></body>
        </html>
        """

        let chapter = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="\(language)">
        <head><title>\(title)</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
        <body><article class="markdown-body">\(body)</article></body>
        </html>
        """

        var archive = ZipWriter()
        archive.add("mimetype", string: "application/epub+zip", compress: false)
        archive.add("META-INF/container.xml", string: """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """)
        archive.add("OEBPS/content.opf", string: package)
        archive.add("OEBPS/nav.xhtml", string: navigation)
        archive.add("OEBPS/chapter.xhtml", string: chapter)
        archive.add("OEBPS/style.css", string: stylesheet)
        for image in images {
            archive.add("OEBPS/\(image.path)", data: image.data, compress: false)
        }
        return archive.finish()
    }

    private static func rewriteImages(in html: String, options: ExportOptions, images: inout [(path: String, data: Data, mediaType: String)]) -> String {
        var result = ""
        var remainder = Substring(html)
        while let range = remainder.range(of: "src=\"") {
            result += remainder[..<range.upperBound]
            remainder = remainder[range.upperBound...]
            guard let end = remainder.firstIndex(of: "\"") else { break }
            let source = String(remainder[..<end])
            remainder = remainder[end...]

            let decoded = (source.removingPercentEncoding ?? source).replacingOccurrences(of: "&amp;", with: "&")
            let fileURL: URL? = if decoded.contains("://") {
                nil
            } else if decoded.hasPrefix("/") {
                URL(fileURLWithPath: decoded)
            } else {
                options.documentDirectory?.appendingPathComponent(decoded)
            }
            let fileExtension = (fileURL?.pathExtension.lowercased()) ?? ""
            let mediaTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "svg": "image/svg+xml", "webp": "image/webp"]
            if let fileURL, let mediaType = mediaTypes[fileExtension], let data = try? Data(contentsOf: fileURL) {
                let path = "images/image\(images.count + 1).\(fileExtension)"
                images.append((path, data, mediaType))
                result += path
            } else {
                result += source
            }
        }
        result += remainder
        return result
    }
}

/// Markdown → LaTeX。包含中文时自动使用 ctex（需 XeLaTeX 编译）。
public struct LatexExporter: Sendable {
    public init() {}

    public func export(_ markdown: String, options: ExportOptions) -> String {
        let body = FrontMatter.split(markdown).body
        let document = Markdown.Document(parsing: body, options: [.disableSmartOpts])
        var builder = LatexBuilder(options: options)
        builder.visit(document)

        let needsCJK = markdown.unicodeScalars.contains { (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
        var preamble = [
            "% !TEX program = \(needsCJK ? "xelatex" : "pdflatex")",
            "\\documentclass[11pt]{\(needsCJK ? "ctexart" : "article")}",
            "\\usepackage{graphicx}",
            "\\usepackage{hyperref}",
            "\\usepackage{listings}",
            "\\usepackage[normalem]{ulem}",
            "\\usepackage{booktabs}",
        ]
        if !needsCJK {
            preamble.insert("\\usepackage[utf8]{inputenc}", at: 2)
        }
        preamble.append("\\lstset{basicstyle=\\ttfamily\\small, breaklines=true, frame=single}")
        preamble.append("\\title{\(LatexBuilder.escape(options.title))}")
        preamble.append("\\date{}")

        return preamble.joined(separator: "\n") + "\n\n\\begin{document}\n\\maketitle\n\n" + builder.output + "\\end{document}\n"
    }
}

private struct LatexBuilder: MarkupVisitor {
    typealias Result = Void

    let options: ExportOptions
    var output = ""

    init(options: ExportOptions) {
        self.options = options
    }

    static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "\\": result += "\\textbackslash{}"
            case "{": result += "\\{"
            case "}": result += "\\}"
            case "$": result += "\\$"
            case "&": result += "\\&"
            case "#": result += "\\#"
            case "^": result += "\\textasciicircum{}"
            case "_": result += "\\_"
            case "%": result += "\\%"
            case "~": result += "\\textasciitilde{}"
            default: result.append(character)
            }
        }
        return result
    }

    mutating func defaultVisit(_ markup: any Markup) {
        for child in markup.children {
            visit(child)
        }
    }

    mutating func visitHeading(_ heading: Heading) {
        let commands = ["section", "subsection", "subsubsection", "paragraph", "subparagraph", "subparagraph"]
        output += "\\\(commands[min(heading.level, 6) - 1]){"
        defaultVisit(heading)
        output += "}\n\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        defaultVisit(paragraph)
        output += paragraph.parent is ListItem ? "\n" : "\n\n"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        output += "\\begin{quote}\n"
        defaultVisit(blockQuote)
        output += "\\end{quote}\n\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        output += "\\begin{lstlisting}\n\(codeBlock.code)\\end{lstlisting}\n\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        output += "\\noindent\\rule{\\linewidth}{0.4pt}\n\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {}

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        output += "\\begin{itemize}\n"
        defaultVisit(unorderedList)
        output += "\\end{itemize}\n\n"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        output += "\\begin{enumerate}\n"
        if orderedList.startIndex != 1 {
            output += "\\setcounter{enumi}{\(orderedList.startIndex - 1)}\n"
        }
        defaultVisit(orderedList)
        output += "\\end{enumerate}\n\n"
    }

    mutating func visitListItem(_ listItem: ListItem) {
        switch listItem.checkbox {
        case .checked: output += "\\item[$\\boxtimes$] "
        case .unchecked: output += "\\item[$\\square$] "
        case nil: output += "\\item "
        }
        defaultVisit(listItem)
    }

    mutating func visitTable(_ table: Table) {
        let columns = max(table.maxColumnCount, 1)
        let specification = table.columnAlignments.prefix(columns).map { alignment -> String in
            switch alignment {
            case .center: "c"
            case .right: "r"
            default: "l"
            }
        }.joined() + String(repeating: "l", count: max(0, columns - table.columnAlignments.count))
        output += "\\begin{center}\n\\begin{tabular}{\(specification)}\n\\toprule\n"

        func row(_ cells: [Table.Cell], builder: inout LatexBuilder) {
            for (index, cell) in cells.enumerated() {
                if index > 0 { builder.output += " & " }
                builder.defaultVisit(cell)
            }
            builder.output += " \\\\\n"
        }
        row(Array(table.head.cells), builder: &self)
        output += "\\midrule\n"
        for bodyRow in table.body.rows {
            row(Array(bodyRow.cells), builder: &self)
        }
        output += "\\bottomrule\n\\end{tabular}\n\\end{center}\n\n"
    }

    mutating func visitText(_ text: Markdown.Text) {
        output += Self.escape(text.string)
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        output += " "
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        output += "\\\\\n"
    }

    mutating func visitStrong(_ strong: Strong) {
        output += "\\textbf{"
        defaultVisit(strong)
        output += "}"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        output += "\\emph{"
        defaultVisit(emphasis)
        output += "}"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        output += "\\sout{"
        defaultVisit(strikethrough)
        output += "}"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        output += "\\texttt{\(Self.escape(inlineCode.code))}"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {}

    mutating func visitLink(_ link: Markdown.Link) {
        guard let destination = link.destination, !destination.isEmpty else {
            defaultVisit(link)
            return
        }
        output += "\\href{\(destination.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "#", with: "\\#"))}{"
        defaultVisit(link)
        output += "}"
    }

    mutating func visitImage(_ image: Markdown.Image) {
        guard let source = image.source, !source.contains("://") else {
            output += Self.escape(image.plainText)
            return
        }
        output += "\\begin{center}\\includegraphics[width=0.8\\linewidth]{\(source)}\\end{center}\n"
    }
}
