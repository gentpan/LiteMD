import Foundation
import LiteMDMarkdown

/// 内置导入格式。PDF、图片（OCR）、RTF / DOC / ODT 依赖系统框架，由平台层实现。
public enum ImportFormat: String, CaseIterable, Sendable {
    case docx
    case pptx
    case xlsx
    case epub
    case html
    case csv
    case json
    case xml
    case text

    public static func format(forExtension fileExtension: String) -> ImportFormat? {
        switch fileExtension.lowercased() {
        case "docx", "docm", "dotx": .docx
        case "pptx", "pptm": .pptx
        case "xlsx", "xlsm": .xlsx
        case "epub": .epub
        case "html", "htm", "xhtml": .html
        case "csv", "tsv": .csv
        case "json": .json
        case "xml": .xml
        case "txt", "text", "log": .text
        default: nil
        }
    }
}

/// 导入入口：按扩展名分发到对应的转换器。
public struct DocumentImporter: Sendable {
    public init() {}

    public func convert(_ data: Data, fileName: String, options: ImportOptions) throws(ConversionError) -> ConversionResult {
        let fileExtension = (fileName as NSString).pathExtension
        guard let format = ImportFormat.format(forExtension: fileExtension) else {
            throw ConversionError.unsupported(fileExtension)
        }
        let title = (fileName as NSString).deletingPathExtension

        switch format {
        case .docx:
            return try DocxImporter().convert(data, options: options)
        case .pptx:
            return try PptxImporter().convert(data, options: options)
        case .xlsx:
            return try XlsxImporter().convert(data, options: options)
        case .epub:
            return try EpubImporter().convert(data, options: options)
        case .html:
            let root = HTMLTagSoupParser.parse(Self.decode(data))
            let converter = HTMLMarkdownConverter()
            let markdown = converter.convert(root)
            guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConversionError.empty }
            return ConversionResult(markdown: markdown, title: converter.title(of: root) ?? title)
        case .csv:
            return try CsvImporter().convert(Self.decode(data))
        case .json:
            let pretty = (try? JSONSerialization.jsonObject(with: data))
                .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) }
                .map { String(decoding: $0, as: UTF8.self) } ?? Self.decode(data)
            return ConversionResult(markdown: "```json\n\(pretty)\n```\n", title: title)
        case .xml:
            return ConversionResult(markdown: "```xml\n\(Self.decode(data).trimmingCharacters(in: .newlines))\n```\n", title: title)
        case .text:
            return ConversionResult(markdown: Self.decode(data), title: title)
        }
    }

    /// 先看 BOM 与明显的 UTF-16，再试 UTF-8，最后 GB 18030（常见中文编码）。
    ///
    /// UTF-16 几乎能“解码”任何偶数长度的字节，只凭能否解码就先试它，GBK 文本会变成一串韩文；
    /// 反过来，西文 UTF-16 里的零字节又是合法的 UTF-8，所以 UTF-16 的判断要放在 UTF-8 之前。
    static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: bytes.dropFirst(3), as: UTF8.self)
        }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            if let text = String(data: data, encoding: .utf16) { return text }
        }
        if let littleEndian = looksLikeUTF16(bytes) {
            if let text = String(data: data, encoding: littleEndian ? .utf16LittleEndian : .utf16BigEndian) { return text }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let text = String(data: data, encoding: gb18030) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    /// 没有 BOM 的 UTF-16：西文字符的高位字节是 0，零字节集中在奇数位（小端）或偶数位（大端）。
    /// 返回 nil 表示不像 UTF-16。
    static func looksLikeUTF16(_ bytes: [UInt8]) -> Bool? {
        let sample = bytes.prefix(4096)
        guard sample.count >= 2, sample.count % 2 == 0 else { return nil }
        var zerosAtEven = 0
        var zerosAtOdd = 0
        for (offset, byte) in sample.enumerated() where byte == 0 {
            if offset % 2 == 0 { zerosAtEven += 1 } else { zerosAtOdd += 1 }
        }
        let pairs = sample.count / 2
        if zerosAtOdd * 10 >= pairs * 3, zerosAtEven * 20 <= pairs { return true }
        if zerosAtEven * 10 >= pairs * 3, zerosAtOdd * 20 <= pairs { return false }
        return nil
    }
}

/// 容错的 HTML 解析：真实网页通常不是合法 XML（未闭合标签、空元素、实体）。
public enum HTMLTagSoupParser {
    static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
    static let rawTextElements: Set<String> = ["script", "style", "textarea", "title"]
    /// 遇到这些块级开始标签时，自动闭合尚未闭合的 `<p>`。
    static let closesParagraph: Set<String> = ["p", "div", "ul", "ol", "table", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "blockquote", "section", "article", "header", "footer", "hr"]

    public static func parse(_ html: String) -> XElement {
        let root = XElement(name: "html")
        var stack: [XElement] = [root]
        let scalars = Array(html.unicodeScalars)
        var index = 0
        var text = ""

        func flushText() {
            guard !text.isEmpty else { return }
            stack.last?.append(.text(HTMLEscaping.decodeEntities(text)))
            text = ""
        }

        func close(_ name: String) {
            guard let position = stack.lastIndex(where: { $0.localName == name }), position > 0 else { return }
            stack.removeSubrange(position...)
        }

        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "<" else {
                text.unicodeScalars.append(scalar)
                index += 1
                continue
            }

            // 注释与声明
            if starts(scalars, index, "<!--") {
                flushText()
                index = find(scalars, "-->", from: index + 4).map { $0 + 3 } ?? scalars.count
                continue
            }
            if index + 1 < scalars.count, scalars[index + 1] == "!" || scalars[index + 1] == "?" {
                flushText()
                index = find(scalars, ">", from: index).map { $0 + 1 } ?? scalars.count
                continue
            }

            // 与 Preview 净化器同一个标签解析：带引号的属性值里的 `>` 不会截断标签。
            guard let tag = HTMLTag.parse(scalars, at: index) else {
                text.unicodeScalars.append(scalar)
                index += 1
                continue
            }
            let name = tag.name

            flushText()
            index = tag.end

            if tag.isClosing {
                close(name)
                continue
            }

            if closesParagraph.contains(name), stack.last?.localName == "p" { stack.removeLast() }
            // 可省略闭合标签的元素：遇到同级新元素时自动闭合上一个（不跨越其容器）。
            let implicitClosing: [String: (closes: Set<String>, boundary: Set<String>)] = [
                "li": (["li"], ["ul", "ol"]),
                "td": (["td", "th"], ["tr", "table"]),
                "th": (["td", "th"], ["tr", "table"]),
                "tr": (["tr", "td", "th"], ["table", "thead", "tbody", "tfoot"]),
                "dt": (["dt", "dd"], ["dl"]),
                "dd": (["dt", "dd"], ["dl"]),
                "option": (["option"], ["select"]),
            ]
            if let rule = implicitClosing[name],
               let open = stack.lastIndex(where: { rule.closes.contains($0.localName) }),
               !stack[(open + 1)...].contains(where: { rule.boundary.contains($0.localName) }),
               open > 0 {
                stack.removeSubrange(open...)
            }

            // 重复的属性以第一个为准，与浏览器一致。
            let attributes = Dictionary(tag.attributes.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            let element = XElement(name: name, attributes: attributes)
            stack.last?.append(.element(element))

            if rawTextElements.contains(name) {
                let closing = "</\(name)"
                let end = findCaseInsensitive(scalars, closing, from: index) ?? scalars.count
                element.append(.text(String(String.UnicodeScalarView(scalars[index..<end]))))
                index = find(scalars, ">", from: end).map { $0 + 1 } ?? scalars.count
                continue
            }
            if !voidElements.contains(name), !tag.isSelfClosing {
                stack.append(element)
            }
        }
        flushText()
        return root
    }

    private static func starts(_ scalars: [Unicode.Scalar], _ index: Int, _ literal: String) -> Bool {
        let pattern = Array(literal.unicodeScalars)
        guard index + pattern.count <= scalars.count else { return false }
        return scalars[index..<(index + pattern.count)].elementsEqual(pattern)
    }

    private static func find(_ scalars: [Unicode.Scalar], _ literal: String, from start: Int) -> Int? {
        var index = start
        while index < scalars.count {
            if starts(scalars, index, literal) { return index }
            index += 1
        }
        return nil
    }

    private static func findCaseInsensitive(_ scalars: [Unicode.Scalar], _ literal: String, from start: Int) -> Int? {
        let pattern = Array(literal.lowercased().unicodeScalars)
        var index = start
        while index + pattern.count <= scalars.count {
            var matched = true
            for offset in 0..<pattern.count {
                let value = scalars[index + offset]
                let lowered = (65...90).contains(value.value) ? Unicode.Scalar(value.value + 32)! : value
                if lowered != pattern[offset] {
                    matched = false
                    break
                }
            }
            if matched { return index }
            index += 1
        }
        return nil
    }
}
