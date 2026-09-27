import Foundation
import LiteMDDomain
import Markdown

/// Markdown Parser（spec §115）。只做 Text → AST / Metadata / HTML。
///
/// 禁止写文件、改选区、改正文、操作 UI、访问数据库（spec §98）。
public struct MarkdownParser: MarkdownParsing {
    /// Preview 使用的本地资源协议前缀，例如 `litemd-asset://file`。
    /// `file://` 地址会被改写为该前缀加绝对路径。
    public var fileURLPrefix: String?

    public init(fileURLPrefix: String? = nil) {
        self.fileURLPrefix = fileURLPrefix
    }

    @concurrent
    public func parse(_ text: String, documentID: DocumentID, revision: Int, options: MarkdownParseOptions) async -> ParseResult {
        parseSynchronously(text, documentID: documentID, revision: revision)
    }

    public func parseSynchronously(_ text: String, documentID: DocumentID, revision: Int) -> ParseResult {
        let prepared = Self.prepare(text)
        var renderer = HTMLRenderer(placeholders: prepared.placeholders, lineStartOffsets: Self.lineStartOffsets(text), fileURLPrefix: fileURLPrefix)
        renderer.visit(prepared.document)

        var html = renderer.output
        if let yaml = prepared.frontMatter {
            html = "<pre class=\"front-matter\" data-line=\"1\"><code>\(HTMLEscaping.text(yaml))</code></pre>\n" + html
        }

        return ParseResult(
            documentID: documentID,
            revision: revision,
            headings: renderer.headings,
            links: renderer.links,
            images: renderer.images,
            codeBlocks: renderer.codeBlocks,
            wikiLinks: prepared.wikiLinks,
            statistics: DocumentStatisticsCounter.compute(text),
            html: html
        )
    }

    /// Preview、导出与复制共用的前半段：拆出 Front Matter，扩展语法换成占位符，再交给 CommonMark。
    struct Prepared {
        var frontMatter: String?
        var placeholders: ExtensionPlaceholders
        var document: Document
        var wikiLinks: [WikiLink]
    }

    static func prepare(_ text: String) -> Prepared {
        let frontMatter = FrontMatter.split(text)
        let scan = MarkdownExtensionScanner.scan(frontMatter.body)
        let placeholders = ExtensionPlaceholders(text: frontMatter.body, scan: scan)
        let document = Document(parsing: placeholders.text, options: [.disableSmartOpts])
        return Prepared(frontMatter: frontMatter.yaml, placeholders: placeholders, document: document, wikiLinks: scan.wikiLinks)
    }

    static func lineStartOffsets(_ text: String) -> [Int] {
        var offsets = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A { offsets.append(offset) }
        }
        return offsets
    }
}

/// YAML Front Matter（spec §40）。
public enum FrontMatter {
    public struct Split: Sendable {
        /// Front Matter 被替换为等量空行后的正文，保证 AST 行号与原文一致。
        public var body: String
        public var yaml: String?
    }

    public static func split(_ text: String) -> Split {
        guard text.hasPrefix("---") else { return Split(body: text, yaml: nil) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return Split(body: text, yaml: nil)
        }
        for index in 1..<lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." {
                let yaml = lines[1..<index].joined(separator: "\n")
                let blankLines = String(repeating: "\n", count: index + 1)
                let rest = lines[(index + 1)...].joined(separator: "\n")
                return Split(body: blankLines + rest, yaml: yaml)
            }
        }
        return Split(body: text, yaml: nil)
    }
}
