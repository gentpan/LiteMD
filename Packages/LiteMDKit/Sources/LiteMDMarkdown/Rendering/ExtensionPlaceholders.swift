import Foundation
import LiteMDDomain

/// 双链与公式不属于 CommonMark。解析前把它们替换为私用区占位符（保持行号不变），
/// 渲染时再按所在位置处理：正文里换成 HTML；代码、原始 HTML、链接与图片地址里先还原为原文，
/// 再照常转义或净化。这样扩展语法里的引号、尖括号永远跳不出所在的标签或属性。
///
/// 正文里本来就有的 U+E000 / U+E001 也登记为占位符，渲染时原样还原，不会与真正的占位符混淆。
struct ExtensionPlaceholders: Sendable {
    enum Item: Sendable {
        case wikiLink(WikiLink)
        case math(MathSpan)
        /// 正文中原有的占位字符。
        case literal
    }

    private static let open: Unicode.Scalar = "\u{E000}"
    private static let close: Unicode.Scalar = "\u{E001}"

    private(set) var items: [(item: Item, source: String)] = []
    /// 替换后的正文。
    private(set) var text: String

    init(text: String, scan: MarkdownExtensionScanner.Result) {
        var entries: [(range: NSRange, item: Item)] = scan.wikiLinks.map { ($0.range, .wikiLink($0)) }
        entries += scan.math.map { ($0.range, .math($0)) }
        var offset = 0
        for unit in text.utf16 {
            if unit == 0xE000 || unit == 0xE001 {
                entries.append((NSRange(location: offset, length: 1), .literal))
            }
            offset += 1
        }
        entries.sort { $0.range.location < $1.range.location }

        let source = text as NSString
        var result = ""
        var cursor = 0
        // 双链、公式内部的占位字符随原文一起保存，不再单独登记。
        for entry in entries where entry.range.location >= cursor {
            result += source.substring(with: NSRange(location: cursor, length: entry.range.location - cursor))
            let original = source.substring(with: entry.range)
            let index = items.count
            items.append((entry.item, original))
            result.unicodeScalars.append(Self.open)
            result += String(index)
            result.unicodeScalars.append(Self.close)
            // 多行公式：补回换行，后续内容的行号保持不变。
            result += String(repeating: "\n", count: original.utf16.count { $0 == 0x0A })
            cursor = NSMaxRange(entry.range)
        }
        result += source.substring(from: cursor)
        self.text = result
    }

    /// 在已转义的正文 HTML 中把占位符换成渲染结果。
    ///
    /// - Parameters:
    ///   - linksWikiTargets: Preview 中双链是可点击的 `litemd-wiki:` 链接；导出与复制到别的应用时只保留显示文字。
    ///   - imageSource: 图片地址的净化与改写，返回 nil 表示不能显示。
    func renderHTML(in escaped: String, xhtml: Bool, linksWikiTargets: Bool, imageSource: (String) -> String?) -> String {
        replace(in: escaped) { index in
            let entry = items[index]
            switch entry.item {
            case .wikiLink(let link):
                return Self.html(for: link, xhtml: xhtml, linksWikiTargets: linksWikiTargets, imageSource: imageSource)
            case .math(let math):
                let tex = HTMLEscaping.text(math.tex)
                if xhtml { return "<code class=\"math\">\(tex)</code>" }
                return math.isDisplay
                    ? "<span class=\"math math-display\">\(tex)</span>"
                    : "<span class=\"math math-inline\">\(tex)</span>"
            case .literal:
                return HTMLEscaping.text(entry.source)
            }
        }
    }

    /// 纯文本场景（标题、替代文字）：双链显示文字，公式保留源码。
    func plainText(_ string: String) -> String {
        replace(in: string) { index in
            switch items[index].item {
            case .wikiLink(let link): link.displayText
            case .math, .literal: items[index].source
            }
        }
    }

    /// 代码、原始 HTML、链接地址等不解释扩展语法的位置：还原为原文，由调用方继续转义或净化。
    func source(_ string: String) -> String {
        replace(in: string) { items[$0].source }
    }

    /// 按占位符切分：`text` 收到普通文字（原有的占位字符已还原），`item` 收到双链与公式。
    func forEachSegment(in string: String, text: (String) -> Void, item: (Item) -> Void) {
        var pending = ""
        walk(string, text: { pending.unicodeScalars.append(contentsOf: $0) }, placeholder: { index in
            let entry = items[index]
            if case .literal = entry.item {
                pending += entry.source
                return
            }
            if !pending.isEmpty { text(pending) }
            pending = ""
            item(entry.item)
        })
        if !pending.isEmpty { text(pending) }
    }

    private func replace(in string: String, with transform: (Int) -> String) -> String {
        guard !items.isEmpty, string.unicodeScalars.contains(Self.open) else { return string }
        var result = String.UnicodeScalarView()
        walk(string, text: { result.append(contentsOf: $0) }, placeholder: { result.append(contentsOf: transform($0).unicodeScalars) })
        return String(result)
    }

    /// 只认 “U+E000 + 十进制编号 + U+E001” 这一种形式。按 Unicode 标量比较：
    /// 占位符后紧跟组合字符时会与之合成一个字形，按字符比较就会漏掉。
    private func walk(_ string: String, text: (Substring.UnicodeScalarView) -> Void, placeholder: (Int) -> Void) {
        let scalars = string.unicodeScalars
        var runStart = scalars.startIndex
        var index = runStart
        while index < scalars.endIndex {
            guard scalars[index] == Self.open else {
                index = scalars.index(after: index)
                continue
            }
            var cursor = scalars.index(after: index)
            var number = 0
            var digits = 0
            while cursor < scalars.endIndex, digits < 9, ("0"..."9").contains(scalars[cursor]) {
                number = number * 10 + Int(scalars[cursor].value - 0x30)
                digits += 1
                cursor = scalars.index(after: cursor)
            }
            guard digits > 0, cursor < scalars.endIndex, scalars[cursor] == Self.close, items.indices.contains(number) else {
                index = scalars.index(after: index)
                continue
            }
            if runStart < index { text(scalars[runStart..<index]) }
            placeholder(number)
            index = scalars.index(after: cursor)
            runStart = index
        }
        if runStart < scalars.endIndex { text(scalars[runStart...]) }
    }

    static let wikiScheme = "litemd-wiki"

    private static func html(for link: WikiLink, xhtml: Bool, linksWikiTargets: Bool, imageSource: (String) -> String?) -> String {
        if link.isEmbed, MarkdownFileType.isImage(URL(fileURLWithPath: link.target)), let src = imageSource(link.target) {
            let attributes = "class=\"wikilink-embed\" src=\"\(HTMLEscaping.attribute(src))\" alt=\"\(HTMLEscaping.attribute(link.displayText))\""
            return xhtml ? "<img \(attributes)/>" : "<img \(attributes) loading=\"lazy\">"
        }
        let text = HTMLEscaping.text(link.displayText)
        guard linksWikiTargets else { return "<span class=\"wikilink\">\(text)</span>" }
        return "<a class=\"wikilink\" href=\"\(HTMLEscaping.attribute(wikiURL(target: link.target, anchor: link.anchor)))\">\(text)</a>"
    }

    /// `litemd-wiki:Project%20Plan#Heading`
    static func wikiURL(target: String, anchor: String?) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "#?")
        var url = "\(wikiScheme):" + (target.addingPercentEncoding(withAllowedCharacters: allowed) ?? target)
        if let anchor {
            url += "#" + (anchor.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? anchor)
        }
        return url
    }
}
