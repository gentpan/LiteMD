import Foundation
import LiteMDDomain
import Markdown

/// 只收集大纲，不生成 HTML：没有显示预览时（源码、实时预览模式）用它代替完整渲染。
/// 标题条目的生成规则与 HTMLRenderer 共用，锚点和行号保持一致。
struct HeadingCollector: MarkupWalker {
    let placeholders: ExtensionPlaceholders
    let lineStartOffsets: [Int]
    private(set) var headings: [HeadingItem] = []
    private var slugger = HeadingSlugger()

    init(placeholders: ExtensionPlaceholders, lineStartOffsets: [Int]) {
        self.placeholders = placeholders
        self.lineStartOffsets = lineStartOffsets
    }

    mutating func visitHeading(_ heading: Heading) {
        headings.append(Self.item(for: heading, index: headings.count, placeholders: placeholders, lineStartOffsets: lineStartOffsets, slugger: &slugger))
    }

    // 标题只会出现在文档、引用和列表里。段落、表格等叶子块不再往下遍历行内节点，
    // 大文档里这部分占了大纲收集的大头。
    mutating func visitParagraph(_ paragraph: Paragraph) {}
    mutating func visitTable(_ table: Table) {}
    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {}
    mutating func visitHTMLBlock(_ html: HTMLBlock) {}

    static func item(for heading: Heading, index: Int, placeholders: ExtensionPlaceholders, lineStartOffsets: [Int], slugger: inout HeadingSlugger) -> HeadingItem {
        let title = placeholders.plainText(heading.plainText)
        let line = heading.range?.lowerBound.line ?? 1
        let offset = line - 1 < lineStartOffsets.count ? lineStartOffsets[line - 1] : 0
        return HeadingItem(index: index, level: heading.level, title: title, line: line, offset: offset, anchor: slugger.slug(for: title))
    }
}
