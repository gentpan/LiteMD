import Foundation
import LiteMDDomain
import Markdown

/// 把 AST 渲染为 Preview HTML，并在同一次遍历中收集 Outline。
///
/// 块级元素带 `data-line`（源文件行号），用于 Split Preview 的块级滚动同步（spec §129）。
struct HTMLRenderer: MarkupVisitor {
    typealias Result = Void

    /// 双链与公式占位符。
    let placeholders: ExtensionPlaceholders
    let lineStartOffsets: [Int]
    let fileURLPrefix: String?
    let includesSourceLines: Bool
    /// EPUB 需要合法的 XHTML：空元素自闭合，原始 HTML 作为文本转义输出。
    var xhtml = false
    /// Preview 中双链是可点击的 `litemd-wiki:` 链接；导出与复制到别的应用时只保留显示文字。
    var linksWikiTargets = true
    /// 导出 EPUB 时把本地图片换成包内路径；返回 nil 时按普通规则处理。
    var imageSource: ((String) -> String?)?

    private(set) var output = ""
    private(set) var headings: [HeadingItem] = []
    private var slugger = HeadingSlugger()

    init(placeholders: ExtensionPlaceholders, lineStartOffsets: [Int], fileURLPrefix: String?, includesSourceLines: Bool = true) {
        self.placeholders = placeholders
        self.lineStartOffsets = lineStartOffsets
        self.fileURLPrefix = fileURLPrefix
        self.includesSourceLines = includesSourceLines
        output.reserveCapacity(4096)
    }

    mutating func defaultVisit(_ markup: Markup) {
        for child in markup.children {
            visit(child)
        }
    }

    private func lineAttribute(_ markup: Markup) -> String {
        guard includesSourceLines, let line = markup.range?.lowerBound.line else { return "" }
        return " data-line=\"\(line)\""
    }

    // MARK: Blocks

    mutating func visitDocument(_ document: Document) {
        defaultVisit(document)
    }

    mutating func visitHeading(_ heading: Heading) {
        let item = HeadingCollector.item(for: heading, index: headings.count, placeholders: placeholders, lineStartOffsets: lineStartOffsets, slugger: &slugger)
        headings.append(item)
        let anchor = item.anchor

        output += "<h\(heading.level) id=\"\(HTMLEscaping.attribute(anchor))\"\(lineAttribute(heading))>"
        defaultVisit(heading)
        output += "</h\(heading.level)>\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        output += "<p\(lineAttribute(paragraph))>"
        defaultVisit(paragraph)
        output += "</p>\n"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        output += "<blockquote\(lineAttribute(blockQuote))>\n"
        defaultVisit(blockQuote)
        output += "</blockquote>\n"
    }

    // 占位符出现在代码、原始 HTML、链接与图片地址里时（扩展语法扫描与 CommonMark 判断不一致，
    // 或者本来就写在属性值里），一律先还原为原文，再转义或净化。

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        let language = codeBlock.language.map(placeholders.source)?.split(separator: " ").first.map(String.init)
        let code = placeholders.source(codeBlock.code)

        // Mermaid 图表与 ```math 公式块由 Preview 脚本渲染；导出为 XHTML 时保留源码。
        if !xhtml, let language = language?.lowercased() {
            if language == "mermaid" {
                output += "<div class=\"mermaid-block\"\(lineAttribute(codeBlock))><pre class=\"mermaid-source\">\(HTMLEscaping.text(code))</pre></div>\n"
                return
            }
            if language == "math" {
                output += "<div class=\"math math-display\"\(lineAttribute(codeBlock))>\(HTMLEscaping.text(code))</div>\n"
                return
            }
        }

        let classAttribute = language.map { " class=\"language-\(HTMLEscaping.attribute($0))\"" } ?? ""
        output += "<pre\(lineAttribute(codeBlock))><code\(classAttribute)>"
        output += HTMLEscaping.text(code)
        output += "</code></pre>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        output += "<hr\(lineAttribute(thematicBreak))\(xhtml ? "/" : "")>\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        let raw = placeholders.source(html.rawHTML)
        output += xhtml ? "<p>" + HTMLEscaping.text(raw) + "</p>\n" : HTMLSanitizer.sanitize(raw, fileURLPrefix: fileURLPrefix)
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        let start = orderedList.startIndex != 1 ? " start=\"\(orderedList.startIndex)\"" : ""
        output += "<ol\(start)\(lineAttribute(orderedList))>\n"
        defaultVisit(orderedList)
        output += "</ol>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        let isTaskList = unorderedList.listItems.contains { $0.checkbox != nil }
        let classAttribute = isTaskList ? " class=\"contains-task-list\"" : ""
        output += "<ul\(classAttribute)\(lineAttribute(unorderedList))>\n"
        defaultVisit(unorderedList)
        output += "</ul>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) {
        let checkboxHTML: String
        let classAttribute: String
        switch listItem.checkbox {
        case .checked:
            checkboxHTML = xhtml ? "<input type=\"checkbox\" disabled=\"disabled\" checked=\"checked\"/> " : "<input type=\"checkbox\" disabled checked> "
            classAttribute = " class=\"task-list-item checked\""
        case .unchecked:
            checkboxHTML = xhtml ? "<input type=\"checkbox\" disabled=\"disabled\"/> " : "<input type=\"checkbox\" disabled> "
            classAttribute = " class=\"task-list-item\""
        case nil:
            checkboxHTML = ""
            classAttribute = ""
        }

        output += "<li\(classAttribute)\(lineAttribute(listItem))>"
        let children = Array(listItem.children)
        if children.count == 1, let paragraph = children[0] as? Paragraph {
            // 紧凑列表：单段落直接内联，复选框与文字同一行。
            output += checkboxHTML
            defaultVisit(paragraph)
        } else {
            for (index, child) in children.enumerated() {
                if index == 0, let paragraph = child as? Paragraph {
                    output += "<p\(lineAttribute(paragraph))>" + checkboxHTML
                    defaultVisit(paragraph)
                    output += "</p>\n"
                } else {
                    if index == 0 { output += checkboxHTML }
                    visit(child)
                }
            }
        }
        output += "</li>\n"
    }

    mutating func visitTable(_ table: Table) {
        let alignments = table.columnAlignments
        output += "<div class=\"table-wrapper\"\(lineAttribute(table))><table>\n<thead>\n<tr>"
        for (column, cell) in table.head.cells.enumerated() {
            renderCell(cell, tag: "th", alignment: column < alignments.count ? alignments[column] : nil)
        }
        output += "</tr>\n</thead>\n<tbody>\n"
        for row in table.body.rows {
            output += "<tr>"
            for (column, cell) in row.cells.enumerated() {
                renderCell(cell, tag: "td", alignment: column < alignments.count ? alignments[column] : nil)
            }
            output += "</tr>\n"
        }
        output += "</tbody>\n</table></div>\n"
    }

    private mutating func renderCell(_ cell: Table.Cell, tag: String, alignment: Table.ColumnAlignment?) {
        // colspan / rowspan 为 0 的单元格已被相邻单元格合并。
        guard cell.colspan > 0, cell.rowspan > 0 else { return }
        var attributes = ""
        switch alignment {
        case .left: attributes += " style=\"text-align: left\""
        case .center: attributes += " style=\"text-align: center\""
        case .right: attributes += " style=\"text-align: right\""
        case nil: break
        }
        if cell.colspan > 1 { attributes += " colspan=\"\(cell.colspan)\"" }
        if cell.rowspan > 1 { attributes += " rowspan=\"\(cell.rowspan)\"" }
        output += "<\(tag)\(attributes)>"
        defaultVisit(cell)
        output += "</\(tag)>"
    }

    // MARK: Inlines

    mutating func visitText(_ text: Markdown.Text) {
        let escaped = Self.renderHighlights(HTMLEscaping.text(text.string))
        output += placeholders.renderHTML(in: escaped, xhtml: xhtml, linksWikiTargets: linksWikiTargets) { source in
            imageSourceAttribute(source)
        }
    }

    /// `==高亮==` 扩展语法（spec §10 Highlight）。只在同一文本节点内配对，开闭标记内侧不能是空白。
    static func renderHighlights(_ escaped: String) -> String {
        guard escaped.contains("==") else { return escaped }
        let parts = escaped.components(separatedBy: "==")
        guard parts.count >= 3 else { return escaped }

        var result = parts[0]
        var index = 1
        while index < parts.count {
            let content = parts[index]
            let canClose = index + 1 < parts.count
            if canClose, !content.isEmpty,
               content.first?.isWhitespace == false, content.last?.isWhitespace == false {
                result += "<mark>" + content + "</mark>" + parts[index + 1]
                index += 2
            } else {
                result += "==" + content
                index += 1
            }
        }
        return result
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        output += "\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        output += xhtml ? "<br/>\n" : "<br>\n"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        output += "<em>"
        defaultVisit(emphasis)
        output += "</em>"
    }

    mutating func visitStrong(_ strong: Strong) {
        output += "<strong>"
        defaultVisit(strong)
        output += "</strong>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        output += "<del>"
        defaultVisit(strikethrough)
        output += "</del>"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        output += "<code>" + HTMLEscaping.text(placeholders.source(inlineCode.code)) + "</code>"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        let raw = placeholders.source(inlineHTML.rawHTML)
        output += xhtml ? HTMLEscaping.text(raw) : HTMLSanitizer.sanitize(raw, fileURLPrefix: fileURLPrefix)
    }

    mutating func visitLink(_ link: Link) {
        let destination = placeholders.source(link.destination ?? "")

        guard let href = URLSanitizer.sanitizeLink(destination) else {
            defaultVisit(link)
            return
        }
        var attributes = " href=\"\(HTMLEscaping.attribute(href))\""
        if let title = link.title.map(placeholders.source), !title.isEmpty {
            attributes += " title=\"\(HTMLEscaping.attribute(title))\""
        }
        output += "<a\(attributes)>"
        defaultVisit(link)
        output += "</a>"
    }

    mutating func visitImage(_ image: Image) {
        let source = placeholders.source(image.source ?? "")
        let alt = placeholders.plainText(image.plainText)

        guard let src = imageSourceAttribute(source) else {
            output += HTMLEscaping.text(alt)
            return
        }
        var attributes = " src=\"\(HTMLEscaping.attribute(src))\" alt=\"\(HTMLEscaping.attribute(alt))\""
        if let title = image.title.map(placeholders.source), !title.isEmpty {
            attributes += " title=\"\(HTMLEscaping.attribute(title))\""
        }
        output += xhtml ? "<img\(attributes)/>" : "<img\(attributes) loading=\"lazy\">"
    }

    mutating func visitSymbolLink(_ symbolLink: SymbolLink) {
        output += "<code>" + HTMLEscaping.text(placeholders.source(symbolLink.destination ?? "")) + "</code>"
    }

    private func imageSourceAttribute(_ source: String) -> String? {
        imageSource?(source) ?? URLSanitizer.sanitizeResource(source, fileURLPrefix: fileURLPrefix)
    }
}

/// GitHub 风格的标题锚点：小写、空白转 `-`、去掉标点，重复时追加序号。
struct HeadingSlugger {
    private var used: [String: Int] = [:]

    mutating func slug(for title: String) -> String {
        var slug = ""
        for scalar in title.lowercased().unicodeScalars {
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar == "-" || scalar == "_" {
                slug.unicodeScalars.append(scalar)
            } else if scalar.properties.isWhitespace {
                slug.append("-")
            }
        }
        if slug.isEmpty { slug = "section" }

        if let count = used[slug] {
            used[slug] = count + 1
            return "\(slug)-\(count)"
        }
        used[slug] = 1
        return slug
    }
}
