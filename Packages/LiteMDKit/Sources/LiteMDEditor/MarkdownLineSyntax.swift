import Foundation
import LiteMDDomain

/// 行级 Markdown 语法识别，供编辑命令使用。只识别 `\n` 换行（正文已统一 LF）。
public enum MarkdownLineSyntax {
    public enum ListKind: Equatable, Sendable {
        case bullet(marker: Character)
        case ordered(number: Int, delimiter: Character)
    }

    public enum TaskState: Equatable, Sendable {
        case unchecked
        case checked
    }

    public struct ListPrefix: Equatable, Sendable {
        public var indent: String
        public var kind: ListKind
        public var task: TaskState?
        /// 前缀总长度（UTF-16），包括缩进、标记、空白与任务框。
        public var length: Int

        public var indentLength: Int { indent.utf16.count }
    }

    public static func parseListPrefix(_ line: String) -> ListPrefix? {
        let units = Array(line.utf16)
        var index = 0
        while index < units.count, isBlank(units[index]) { index += 1 }
        let indentLength = index
        guard index < units.count else { return nil }

        let kind: ListKind
        switch units[index] {
        case 0x2D, 0x2A, 0x2B: // - * +
            kind = .bullet(marker: Character(UnicodeScalar(units[index])!))
            index += 1
        case 0x30...0x39:
            var number = 0
            var digits = 0
            while index < units.count, (0x30...0x39).contains(units[index]), digits < 9 {
                number = number * 10 + Int(units[index] - 0x30)
                digits += 1
                index += 1
            }
            guard index < units.count, units[index] == 0x2E || units[index] == 0x29 else { return nil }
            kind = .ordered(number: number, delimiter: Character(UnicodeScalar(units[index])!))
            index += 1
        default:
            return nil
        }

        // 标记后必须有空白，或者行在标记处结束（空列表项）。
        if index < units.count {
            guard isBlank(units[index]) else { return nil }
        } else {
            return nil
        }
        while index < units.count, isBlank(units[index]) { index += 1 }

        var task: TaskState?
        if index + 2 < units.count,
           units[index] == 0x5B,
           units[index + 2] == 0x5D,
           [0x20, 0x78, 0x58].contains(units[index + 1]) {
            let afterBox = index + 3
            if afterBox == units.count || isBlank(units[afterBox]) {
                task = units[index + 1] == 0x20 ? .unchecked : .checked
                index = afterBox
                while index < units.count, isBlank(units[index]) { index += 1 }
            }
        }

        let indent = String(decoding: units[0..<indentLength], as: UTF16.self)
        return ListPrefix(indent: indent, kind: kind, task: task, length: index)
    }

    /// ATX 标题：返回级别与前缀长度（含 `#` 后的空白）。
    public static func parseHeadingPrefix(_ line: String) -> (level: Int, length: Int)? {
        let units = Array(line.utf16)
        var index = 0
        while index < units.count, index < 3, units[index] == 0x20 { index += 1 }
        var level = 0
        while index < units.count, units[index] == 0x23 {
            level += 1
            index += 1
        }
        guard (1...6).contains(level) else { return nil }
        guard index == units.count || isBlank(units[index]) else { return nil }
        while index < units.count, isBlank(units[index]) { index += 1 }
        return (level, index)
    }

    /// 单层引用前缀 `> ` 的长度。
    public static func parseQuotePrefix(_ line: String) -> Int? {
        let units = Array(line.utf16)
        var index = 0
        while index < units.count, index < 3, units[index] == 0x20 { index += 1 }
        guard index < units.count, units[index] == 0x3E else { return nil }
        index += 1
        if index < units.count, units[index] == 0x20 { index += 1 }
        return index
    }

    /// 多层引用前缀（例如 `> > `）的长度。
    public static func parseNestedQuotePrefix(_ line: String) -> Int? {
        guard var length = parseQuotePrefix(line) else { return nil }
        let units = Array(line.utf16)
        while true {
            let rest = String(decoding: units[length...], as: UTF16.self)
            guard let next = parseQuotePrefix(rest) else { break }
            length += next
        }
        return length
    }

    public static func leadingWhitespaceLength(_ line: String) -> Int {
        var count = 0
        for unit in line.utf16 {
            guard isBlank(unit) else { break }
            count += 1
        }
        return count
    }

    public static func isBlankLine(_ line: String) -> Bool {
        line.utf16.allSatisfy(isBlank)
    }

    /// `location` 是否位于围栏代码块内部（包括围栏行本身之后的内容行）。
    public static func isInsideFencedCodeBlock(_ text: NSString, location: Int) -> Bool {
        let length = min(location, text.length)
        guard length > 0 else { return false }
        var buffer = [UInt16](repeating: 0, count: length)
        text.getCharacters(&buffer, range: NSRange(location: 0, length: length))

        var openFence: MarkdownFence?
        var lineStart = 0
        while lineStart < length {
            var lineEnd = lineStart
            while lineEnd < length, buffer[lineEnd] != 0x0A { lineEnd += 1 }
            // 只处理完整的行（光标所在行不算围栏判断的一部分）。
            guard lineEnd < length else { break }
            if let fence = MarkdownFence.parse(buffer, lineStart, lineEnd) {
                if let open = openFence {
                    if open.isClosed(by: fence) { openFence = nil }
                } else {
                    openFence = fence
                }
            }
            lineStart = lineEnd + 1
        }
        return openFence != nil
    }

    @inline(__always)
    static func isBlank(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09
    }

    /// 格式化链接 / 图片目标。包含空白或括号时使用 `<...>` 包裹。
    public static func linkDestination(_ path: String) -> String {
        let needsAngleBrackets = path.contains { $0.isWhitespace || $0 == "(" || $0 == ")" }
        guard needsAngleBrackets else { return path }
        let escaped = path.replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E")
        return "<\(escaped)>"
    }
}
