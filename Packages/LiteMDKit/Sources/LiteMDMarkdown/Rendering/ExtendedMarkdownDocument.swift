import Foundation
import LiteMDDomain
import Markdown

/// 转换器（DOCX、LaTeX）使用的解析结果：CommonMark 语法树加上双链与公式。
///
/// 与 Preview 同一条流程：扩展语法先换成占位符再交给 CommonMark，公式里的 `_`、`\` 不会被当成 Markdown。
/// 正文文字用 `segments(of:)` 拆出双链与公式；代码、链接地址等位置用 `source(of:)` 还原原文。
public struct ExtendedMarkdownDocument {
    public enum Segment: Equatable, Sendable {
        case text(String)
        case wikiLink(WikiLink)
        case math(MathSpan)
    }

    /// Front Matter 之后的正文。
    public let document: Document
    private let placeholders: ExtensionPlaceholders

    public init(parsing markdown: String) {
        let prepared = MarkdownParser.prepare(markdown)
        document = prepared.document
        placeholders = prepared.placeholders
    }

    /// 文本节点拆成普通文字、双链与公式。
    public func segments(of text: String) -> [Segment] {
        var segments: [Segment] = []
        placeholders.forEachSegment(in: text, text: { segments.append(.text($0)) }, item: { item in
            switch item {
            case .wikiLink(let link): segments.append(.wikiLink(link))
            case .math(let math): segments.append(.math(math))
            case .literal: break
            }
        })
        return segments
    }

    /// 代码、链接与图片地址等不解释扩展语法的位置：还原为原文。
    public func source(of text: String) -> String {
        placeholders.source(text)
    }

    /// 纯文本（图片替代文字等）：双链取显示文字，公式保留源码。
    public func plainText(of text: String) -> String {
        placeholders.plainText(text)
    }
}
