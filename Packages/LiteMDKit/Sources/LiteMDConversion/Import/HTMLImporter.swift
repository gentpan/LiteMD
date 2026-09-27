import Foundation

/// HTML DOM → Markdown。输入为已解析的元素树（XHTML 直接解析；普通 HTML 由平台层先整理为 XML）。
public struct HTMLMarkdownConverter {
    /// 解析 `<img src>`，返回 Markdown 中使用的路径；返回 nil 时保留原地址。
    var resolveImage: (String) -> String?

    public init(resolveImage: @escaping (String) -> String? = { _ in nil }) {
        self.resolveImage = resolveImage
    }

    public func convert(_ root: XElement) -> String {
        let body = root.localName == "body" ? root : (Self.find(root, "body") ?? root)
        var blocks: [String] = []
        convertBlocks(body, into: &blocks, listDepth: 0)
        return MarkdownComposer.joinBlocks(blocks)
    }

    public func title(of root: XElement) -> String? {
        let title = Self.find(root, "title")?.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? title : nil
    }

    static func find(_ element: XElement, _ localName: String) -> XElement? {
        if element.localName == localName { return element }
        for child in element.elements {
            if let match = find(child, localName) { return match }
        }
        return nil
    }

    private static let skipped: Set<String> = ["head", "script", "style", "noscript", "template", "svg", "nav", "button", "form", "iframe"]
    private static let blockElements: Set<String> = [
        "p", "div", "section", "article", "main", "header", "footer", "aside", "figure", "figcaption",
        "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "pre", "blockquote", "table", "hr", "dl", "dt", "dd", "details", "summary",
    ]

    private func convertBlocks(_ element: XElement, into blocks: inout [String], listDepth: Int) {
        var inline: [InlinePiece] = []

        func flushInline() {
            let text = MarkdownComposer.render(inline).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(MarkdownComposer.escapeLineStart(text)) }
            inline = []
        }

        for child in element.children {
            switch child {
            case .text(let text):
                inline.append(.text(Self.collapseWhitespace(text)))
            case .element(let node):
                let name = node.localName
                if Self.skipped.contains(name) { continue }
                guard Self.blockElements.contains(name) else {
                    inline.append(contentsOf: inlinePieces(node, style: InlinePiece.text("")))
                    continue
                }
                flushInline()
                convertBlock(node, into: &blocks, listDepth: listDepth)
            }
        }
        flushInline()
    }

    private func convertBlock(_ node: XElement, into blocks: inout [String], listDepth: Int) {
        let name = node.localName
        switch name {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(String(name.last!)) ?? 1
            let text = renderInline(node)
            if !text.isEmpty { blocks.append(String(repeating: "#", count: level) + " " + text) }
        case "p", "figcaption", "dt", "summary":
            let text = renderInline(node)
            if !text.isEmpty { blocks.append(MarkdownComposer.escapeLineStart(text)) }
        case "hr":
            blocks.append("---")
        case "pre":
            let code = node.textContent.trimmingCharacters(in: .newlines)
            let language = (node.child("code")?["class"] ?? node["class"] ?? "")
                .split(separator: " ")
                .first { $0.hasPrefix("language-") }
                .map { String($0.dropFirst("language-".count)) } ?? ""
            let fence = code.contains("```") ? "~~~~" : "```"
            blocks.append(fence + language + "\n" + code + "\n" + fence)
        case "blockquote":
            var inner: [String] = []
            convertBlocks(node, into: &inner, listDepth: listDepth)
            let quoted = MarkdownComposer.joinBlocks(inner)
                .trimmingCharacters(in: .newlines)
                .components(separatedBy: "\n")
                .map { $0.isEmpty ? ">" : "> " + $0 }
                .joined(separator: "\n")
            if !quoted.isEmpty { blocks.append(quoted) }
        case "ul", "ol":
            blocks.append(renderList(node, ordered: name == "ol", depth: listDepth))
        case "table":
            let rows = collectRows(node)
            if !rows.isEmpty { blocks.append(MarkdownComposer.table(rows)) }
        default:
            convertBlocks(node, into: &blocks, listDepth: listDepth)
        }
    }

    private func collectRows(_ table: XElement) -> [[String]] {
        var rows: [[String]] = []
        func visit(_ element: XElement) {
            for child in element.elements {
                if child.localName == "tr" {
                    rows.append(child.elements.filter { ["td", "th"].contains($0.localName) }.map(renderInline))
                } else if ["thead", "tbody", "tfoot"].contains(child.localName) {
                    visit(child)
                }
            }
        }
        visit(table)
        return rows
    }

    private func renderList(_ list: XElement, ordered: Bool, depth: Int) -> String {
        var lines: [String] = []
        let indent = String(repeating: "    ", count: depth)
        var number = Int(list["start"] ?? "1") ?? 1

        for item in list.elements where item.localName == "li" {
            var inline: [InlinePiece] = []
            var nested: [String] = []
            for child in item.children {
                switch child {
                case .text(let text):
                    inline.append(.text(Self.collapseWhitespace(text)))
                case .element(let node):
                    if node.localName == "ul" || node.localName == "ol" {
                        nested.append(renderList(node, ordered: node.localName == "ol", depth: depth + 1))
                    } else if node.localName == "p" || node.localName == "div" {
                        inline.append(contentsOf: inlinePieces(node, style: .text("")))
                        inline.append(.text(" "))
                    } else if !Self.skipped.contains(node.localName) {
                        inline.append(contentsOf: inlinePieces(node, style: .text("")))
                    }
                }
            }
            var text = MarkdownComposer.render(inline).trimmingCharacters(in: .whitespacesAndNewlines)
            if let checkbox = item.elements.first(where: { $0.localName == "input" && $0["type"] == "checkbox" }) {
                text = (checkbox["checked"] != nil ? "[x] " : "[ ] ") + text
            }
            let marker = ordered ? "\(number)." : "-"
            lines.append(indent + marker + " " + text)
            lines.append(contentsOf: nested)
            number += 1
        }
        return lines.joined(separator: "\n")
    }

    private func renderInline(_ element: XElement) -> String {
        MarkdownComposer.render(inlinePieces(element, style: .text("")))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `style` 携带从祖先继承的格式。
    private func inlinePieces(_ element: XElement, style: InlinePiece) -> [InlinePiece] {
        var current = style
        switch element.localName {
        case "strong", "b": current.bold = true
        case "em", "i", "cite": current.italic = true
        case "del", "s", "strike": current.strikethrough = true
        case "mark": current.highlight = true
        case "a":
            if let href = element["href"], !href.hasPrefix("javascript:") { current.link = href }
        case "br":
            return [.markdown("<br>")]
        case "img":
            guard let source = element["src"], !source.isEmpty else { return [] }
            let path = resolveImage(source) ?? source
            let alt = MarkdownComposer.escapeInline(element["alt"] ?? "")
            return [.markdown("![\(alt)](\(MarkdownComposer.destination(path)))")]
        case "code", "kbd", "samp", "tt":
            var piece = current
            piece.content = .code(element.textContent)
            return [piece]
        case "input":
            return []
        default:
            if Self.skipped.contains(element.localName) { return [] }
        }

        var pieces: [InlinePiece] = []
        for child in element.children {
            switch child {
            case .text(let text):
                var piece = current
                piece.content = .text(Self.collapseWhitespace(text))
                pieces.append(piece)
            case .element(let node):
                pieces.append(contentsOf: inlinePieces(node, style: current))
            }
        }
        return pieces
    }

    static func collapseWhitespace(_ text: String) -> String {
        var result = ""
        var lastWasSpace = false
        for character in text {
            if character.isWhitespace {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(character)
                lastWasSpace = false
            }
        }
        return result
    }
}

/// EPUB → Markdown：按阅读顺序（spine）合并各章节。
public struct EpubImporter: Sendable {
    public init() {}

    public func convert(_ data: Data, options: ImportOptions = ImportOptions()) throws(ConversionError) -> ConversionResult {
        let archive = try ZipArchive(data: data)
        let container = try XMLTree.parse(try archive.data(for: "META-INF/container.xml"))
        guard let packagePath = container.firstDescendant("rootfile")?["full-path"] else {
            throw ConversionError.missingPart("rootfile")
        }
        let package = try XMLTree.parse(try archive.data(for: packagePath))

        var manifest: [String: String] = [:]
        for item in package.descendants("item") {
            if let id = item["id"], let href = item["href"] {
                manifest[id] = ZipArchive.resolve(href.removingPercentEncoding ?? href, relativeTo: packagePath)
            }
        }
        let title = package.firstDescendant("dc:title")?.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let assets = AssetCollector(options: options)

        var blocks: [String] = []
        if let title, !title.isEmpty {
            blocks.append("# " + MarkdownComposer.escapeInline(title))
        }
        for reference in package.descendants("itemref") {
            guard let id = reference["idref"], let chapterPath = manifest[id],
                  let chapterData = try? archive.data(for: chapterPath),
                  let chapter = try? XMLTree.parse(chapterData) else { continue }

            let converter = HTMLMarkdownConverter { source in
                guard !source.contains("://"), !source.hasPrefix("data:") else { return nil }
                let imagePath = ZipArchive.resolve(source.removingPercentEncoding ?? source, relativeTo: chapterPath)
                guard let imageData = try? archive.data(for: imagePath) else { return nil }
                return assets.add(imageData, originalName: imagePath, key: imagePath)
            }
            blocks.append(converter.convert(chapter))
        }

        let markdown = MarkdownComposer.joinBlocks(blocks)
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConversionError.empty }
        return ConversionResult(markdown: markdown, assets: assets.assets, title: title)
    }
}
