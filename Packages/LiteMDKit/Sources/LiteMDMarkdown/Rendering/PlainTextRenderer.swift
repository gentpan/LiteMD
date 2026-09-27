import Foundation
import LiteMDDomain
import Markdown

/// 把 Markdown 转为纯文本（右键 “Copy As › Plain Text”）：去掉语法标记，保留段落与列表结构。
struct PlainTextRenderer: MarkupVisitor {
    typealias Result = Void

    let placeholders: ExtensionPlaceholders
    private(set) var output = ""
    private var listDepth = 0
    private var orderedCounters: [UInt?] = []
    private var isAtListItemStart = false

    init(placeholders: ExtensionPlaceholders) {
        self.placeholders = placeholders
    }

    mutating func defaultVisit(_ markup: Markup) {
        for child in markup.children {
            visit(child)
        }
    }

    private mutating func startBlock() {
        if isAtListItemStart {
            isAtListItemStart = false
            return
        }
        guard !output.isEmpty else { return }
        if listDepth > 0 {
            if !output.hasSuffix("\n") { output += "\n" }
        } else {
            while !output.hasSuffix("\n\n") { output += "\n" }
        }
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        startBlock()
        defaultVisit(paragraph)
    }

    mutating func visitHeading(_ heading: Heading) {
        startBlock()
        defaultVisit(heading)
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        defaultVisit(blockQuote)
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        startBlock()
        var code = placeholders.source(codeBlock.code)
        while code.hasSuffix("\n") { code.removeLast() }
        output += code
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        startBlock()
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {}

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        startBlock()
        listDepth += 1
        orderedCounters.append(nil)
        defaultVisit(unorderedList)
        orderedCounters.removeLast()
        listDepth -= 1
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        startBlock()
        listDepth += 1
        orderedCounters.append(orderedList.startIndex)
        defaultVisit(orderedList)
        orderedCounters.removeLast()
        listDepth -= 1
    }

    mutating func visitListItem(_ listItem: ListItem) {
        if !output.isEmpty, !output.hasSuffix("\n") { output += "\n" }
        output += String(repeating: "    ", count: max(0, listDepth - 1))
        if let number = orderedCounters.last ?? nil {
            output += "\(number). "
            orderedCounters[orderedCounters.count - 1] = number + 1
        } else {
            switch listItem.checkbox {
            case .checked: output += "☑ "
            case .unchecked: output += "☐ "
            case nil: output += "• "
            }
        }
        isAtListItemStart = true
        defaultVisit(listItem)
        isAtListItemStart = false
    }

    mutating func visitTable(_ table: Table) {
        startBlock()
        var rows: [String] = []
        var head = PlainTextRenderer(placeholders: placeholders)
        rows.append(table.head.cells.map { cell -> String in
            head.output = ""
            head.defaultVisit(cell)
            return head.output
        }.joined(separator: "\t"))
        for row in table.body.rows {
            var renderer = PlainTextRenderer(placeholders: placeholders)
            rows.append(row.cells.map { cell -> String in
                renderer.output = ""
                renderer.defaultVisit(cell)
                return renderer.output
            }.joined(separator: "\t"))
        }
        output += rows.joined(separator: "\n")
    }

    mutating func visitText(_ text: Markdown.Text) {
        let stripped = HTMLRenderer.renderHighlights(text.string)
            .replacingOccurrences(of: "<mark>", with: "")
            .replacingOccurrences(of: "</mark>", with: "")
        output += placeholders.plainText(stripped)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        output += placeholders.source(inlineCode.code)
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        output += "\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        output += "\n"
    }

    mutating func visitImage(_ image: Image) {
        output += placeholders.plainText(image.plainText)
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {}

    mutating func visitSymbolLink(_ symbolLink: SymbolLink) {
        output += placeholders.source(symbolLink.destination ?? "")
    }
}

extension MarkdownParser {
    /// 去掉 Markdown 语法后的纯文本。双链保留显示文字，公式保留源码。
    public func plainText(from markdown: String) -> String {
        let prepared = Self.prepare(markdown)
        var renderer = PlainTextRenderer(placeholders: prepared.placeholders)
        renderer.visit(prepared.document)
        return renderer.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// EPUB 等场景使用的 XHTML 片段。标题锚点与正文 `id` 出自同一次渲染，目录可以直接引用。
    ///
    /// - Parameter imageSource: 把图片地址换成包内路径；返回 nil 时按普通规则处理。
    public func xhtmlFragment(from markdown: String, imageSource: ((String) -> String?)? = nil) -> RenderedFragment {
        let prepared = Self.prepare(markdown)
        var renderer = HTMLRenderer(placeholders: prepared.placeholders, lineStartOffsets: [0], fileURLPrefix: nil, includesSourceLines: false)
        renderer.xhtml = true
        renderer.linksWikiTargets = false
        renderer.imageSource = imageSource
        renderer.visit(prepared.document)
        return RenderedFragment(html: renderer.output, headings: renderer.headings)
    }

    /// 可粘贴到其他应用的 HTML 片段（已净化，不含 `data-line`）。双链只保留显示文字。
    public func htmlFragment(from markdown: String) -> String {
        let prepared = Self.prepare(markdown)
        var renderer = HTMLRenderer(placeholders: prepared.placeholders, lineStartOffsets: [0], fileURLPrefix: nil, includesSourceLines: false)
        renderer.linksWikiTargets = false
        renderer.visit(prepared.document)
        return renderer.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 导出用的 HTML 片段与其中的标题。
public struct RenderedFragment: Sendable {
    public var html: String
    public var headings: [HeadingItem]
}
