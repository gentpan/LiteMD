import Foundation

/// Preview 安全边界（spec §127）。
///
/// Markdown 中的原始 HTML 采用“安全子集”策略：
/// - 删除可执行、可嵌入、可提交或会改变页面行为的标签；
/// - 删除所有事件属性（`on*`）以及危险属性；
/// - 链接与资源地址只允许安全协议。
///
/// 这是纵深防御的一层。Preview 还会关闭页面 JavaScript，并设置严格的 CSP。
public enum HTMLSanitizer {
    static let blockedTags: Set<String> = [
        "script", "style", "iframe", "frame", "frameset", "object", "embed", "applet",
        "link", "meta", "base", "form", "input", "button", "textarea", "select", "option",
        "noscript", "template", "portal", "svg", "math", "audio", "video", "source", "track",
        "canvas", "dialog", "title", "head", "body", "html", "xmp", "plaintext", "noembed", "param",
    ]

    /// 这些标签的内容也一并删除。
    static let rawTextTags: Set<String> = ["script", "style", "textarea", "title", "template", "noscript", "xmp", "noembed"]

    static let blockedAttributes: Set<String> = [
        "srcdoc", "formaction", "action", "xmlns", "http-equiv", "autofocus", "ping", "srcset",
    ]

    static let urlAttributes: Set<String> = ["href", "src", "cite", "poster", "background", "longdesc", "xlink:href"]

    public static func sanitize(_ html: String, fileURLPrefix: String? = nil) -> String {
        let scalars = Array(html.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0

        func append(_ string: String) {
            output.append(contentsOf: string.unicodeScalars)
        }

        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "<" else {
                output.append(scalar)
                index += 1
                continue
            }

            // 注释
            if matches(scalars, index, "<!--") {
                if let close = find(scalars, "-->", from: index + 4) {
                    index = close + 3
                } else {
                    index = scalars.count
                }
                continue
            }

            // 声明、处理指令
            if index + 1 < scalars.count, scalars[index + 1] == "!" || scalars[index + 1] == "?" {
                if let close = find(scalars, ">", from: index + 1) {
                    index = close + 1
                } else {
                    index = scalars.count
                }
                continue
            }

            guard let tag = parseTag(scalars, index) else {
                append("&lt;")
                index += 1
                continue
            }

            if blockedTags.contains(tag.name) {
                if !tag.isClosing, !tag.isSelfClosing, rawTextTags.contains(tag.name),
                   let close = findClosingTag(scalars, name: tag.name, from: tag.end) {
                    index = close
                } else {
                    index = tag.end
                }
                continue
            }

            append(tag.isClosing ? "</" : "<")
            append(tag.name)
            if !tag.isClosing {
                for attribute in tag.attributes {
                    guard let value = sanitizeAttribute(name: attribute.name, value: attribute.value, fileURLPrefix: fileURLPrefix) else { continue }
                    if let value {
                        append(" \(attribute.name)=\"\(HTMLEscaping.attribute(value))\"")
                    } else {
                        append(" \(attribute.name)")
                    }
                }
                if tag.isSelfClosing { append(" /") }
            }
            append(">")
            index = tag.end
        }

        return String(output)
    }

    /// 返回 nil 表示删除属性；返回 `.some(nil)` 表示保留无值属性。
    private static func sanitizeAttribute(name: String, value: String?, fileURLPrefix: String?) -> String??  {
        // 属性名原样输出，只保留规范的名字，引号、括号之类一律丢掉。
        guard isValidAttributeName(name) else { return nil }
        if name.hasPrefix("on") || blockedAttributes.contains(name) { return nil }
        guard let value else { return .some(nil) }
        if urlAttributes.contains(name) {
            let sanitized = name == "href"
                ? URLSanitizer.sanitizeLink(value)
                : URLSanitizer.sanitizeResource(value, fileURLPrefix: fileURLPrefix)
            guard let sanitized else { return nil }
            return .some(sanitized)
        }
        if name == "style", value.lowercased().contains("expression(") || value.lowercased().contains("javascript:") {
            return nil
        }
        return .some(value)
    }

    private struct Tag {
        var name: String
        var isClosing: Bool
        var isSelfClosing: Bool
        var attributes: [(name: String, value: String?)]
        var end: Int
    }

    private static func parseTag(_ scalars: [Unicode.Scalar], _ start: Int) -> Tag? {
        var index = start + 1
        var isClosing = false
        if index < scalars.count, scalars[index] == "/" {
            isClosing = true
            index += 1
        }
        guard index < scalars.count, scalars[index].properties.isAlphabetic, scalars[index].isASCII else { return nil }

        var name = ""
        while index < scalars.count, isTagNameScalar(scalars[index]) {
            name.unicodeScalars.append(scalars[index])
            index += 1
        }
        name = name.lowercased()

        var attributes: [(String, String?)] = []
        var isSelfClosing = false

        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == ">" {
                return Tag(name: name, isClosing: isClosing, isSelfClosing: isSelfClosing, attributes: attributes, end: index + 1)
            }
            if scalar.properties.isWhitespace {
                index += 1
                continue
            }
            if scalar == "/" {
                isSelfClosing = true
                index += 1
                continue
            }
            if scalar == "<" { return nil }

            isSelfClosing = false
            var attributeName = ""
            while index < scalars.count {
                let current = scalars[index]
                if current.properties.isWhitespace || current == "=" || current == ">" || current == "/" { break }
                attributeName.unicodeScalars.append(current)
                index += 1
            }
            attributeName = attributeName.lowercased()

            while index < scalars.count, scalars[index].properties.isWhitespace { index += 1 }
            var value: String?
            if index < scalars.count, scalars[index] == "=" {
                index += 1
                while index < scalars.count, scalars[index].properties.isWhitespace { index += 1 }
                var parsed = ""
                if index < scalars.count, scalars[index] == "\"" || scalars[index] == "'" {
                    let quote = scalars[index]
                    index += 1
                    while index < scalars.count, scalars[index] != quote {
                        parsed.unicodeScalars.append(scalars[index])
                        index += 1
                    }
                    index += 1
                } else {
                    while index < scalars.count, !scalars[index].properties.isWhitespace, scalars[index] != ">" {
                        parsed.unicodeScalars.append(scalars[index])
                        index += 1
                    }
                }
                value = HTMLEscaping.decodeBasicEntities(parsed)
            }
            if !attributeName.isEmpty {
                attributes.append((attributeName, value))
            }
        }
        return nil
    }

    private static func isValidAttributeName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first.isASCII, first.properties.isAlphabetic || first == "_" || first == ":" else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || "_:.-".unicodeScalars.contains(scalar))
        }
    }

    private static func isTagNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "-" || scalar == ":")
    }

    private static func matches(_ scalars: [Unicode.Scalar], _ index: Int, _ literal: String) -> Bool {
        let pattern = Array(literal.unicodeScalars)
        guard index + pattern.count <= scalars.count else { return false }
        for offset in 0..<pattern.count where scalars[index + offset] != pattern[offset] {
            return false
        }
        return true
    }

    private static func find(_ scalars: [Unicode.Scalar], _ literal: String, from start: Int) -> Int? {
        var index = start
        while index < scalars.count {
            if matches(scalars, index, literal) { return index }
            index += 1
        }
        return nil
    }

    /// 返回闭合标签之后的位置。
    private static func findClosingTag(_ scalars: [Unicode.Scalar], name: String, from start: Int) -> Int? {
        var index = start
        let needle = Array("</\(name)".unicodeScalars)
        while index < scalars.count {
            if index + needle.count <= scalars.count {
                var matched = true
                for offset in 0..<needle.count {
                    let lhs = String(scalars[index + offset]).lowercased()
                    if lhs != String(needle[offset]) {
                        matched = false
                        break
                    }
                }
                if matched, let close = find(scalars, ">", from: index + needle.count) {
                    return close + 1
                }
            }
            index += 1
        }
        return nil
    }
}

public enum URLSanitizer {
    static let linkSchemes: Set<String> = ["http", "https", "mailto", "tel", "file"]

    /// 链接：允许相对路径、锚点与安全协议。
    public static func sanitizeLink(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = scheme(of: trimmed) else { return trimmed }
        return linkSchemes.contains(scheme) ? trimmed : nil
    }

    /// 图片等资源：允许相对路径、http(s)、`data:image/`，`file:` 会被改写为 Preview 的本地资源协议。
    public static func sanitizeResource(_ raw: String, fileURLPrefix: String?) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = scheme(of: trimmed) else { return trimmed }
        switch scheme {
        case "http", "https":
            return trimmed
        case "data":
            return trimmed.lowercased().hasPrefix("data:image/") ? trimmed : nil
        case "file":
            guard let prefix = fileURLPrefix, let url = URL(string: trimmed), url.isFileURL else { return nil }
            let path = url.path(percentEncoded: true)
            return prefix + path
        default:
            return nil
        }
    }

    /// 返回小写协议名；相对地址返回 nil。浏览器会忽略 URL 中的制表与换行，这里同样先去掉。
    static func scheme(of value: String) -> String? {
        let cleaned = value.unicodeScalars.filter { $0.value > 0x20 || $0 == " " }
        var scheme = ""
        for scalar in cleaned {
            if scalar == ":" {
                return scheme.isEmpty ? nil : scheme.lowercased()
            }
            let isValid = scalar.isASCII && (scalar.properties.isAlphabetic || (scheme.isEmpty == false && (("0"..."9").contains(scalar) || scalar == "+" || scalar == "." || scalar == "-")))
            guard isValid else { return nil }
            scheme.unicodeScalars.append(scalar)
        }
        return nil
    }
}

public enum HTMLEscaping {
    public static func text(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for character in value.unicodeScalars {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            default: result.unicodeScalars.append(character)
            }
        }
        return result
    }

    public static func attribute(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for character in value.unicodeScalars {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.unicodeScalars.append(character)
            }
        }
        return result
    }

    /// 解码属性值中的常见实体，避免 `&#106;avascript:` 之类的绕过。
    static func decodeBasicEntities(_ value: String) -> String {
        guard value.contains("&") else { return value }
        var result = ""
        var index = value.startIndex
        while index < value.endIndex {
            if value[index] == "&", let semicolon = value[index...].firstIndex(of: ";"),
               value.distance(from: index, to: semicolon) <= 10 {
                let entity = String(value[value.index(after: index)..<semicolon])
                if let decoded = decodeEntity(entity) {
                    result.append(decoded)
                    index = value.index(after: semicolon)
                    continue
                }
            }
            result.append(value[index])
            index = value.index(after: index)
        }
        return result
    }

    private static func decodeEntity(_ entity: String) -> Character? {
        switch entity.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "colon": return ":"
        case "tab": return "\t"
        case "newline": return "\n"
        default: break
        }
        if entity.hasPrefix("#x") || entity.hasPrefix("#X"), let value = UInt32(entity.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(value) {
            return Character(scalar)
        }
        if entity.hasPrefix("#"), let value = UInt32(entity.dropFirst()), let scalar = Unicode.Scalar(value) {
            return Character(scalar)
        }
        return nil
    }
}
