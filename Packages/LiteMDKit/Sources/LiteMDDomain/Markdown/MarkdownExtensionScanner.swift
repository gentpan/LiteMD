import Foundation

/// `[[双链]]`：`[[笔记]]`、`[[文件夹/笔记#标题|显示文字]]`、`![[嵌入]]`。
public struct WikiLink: Hashable, Sendable {
    /// 目标笔记（不含扩展名也可以），可以为空（`[[#标题]]` 指向当前文档）。
    public var target: String
    public var anchor: String?
    public var alias: String?
    public var isEmbed: Bool
    /// 源文中的 UTF-16 区间，包含 `[[`、`]]`。
    public var range: NSRange
    /// 从 1 开始的行号。
    public var line: Int

    public init(target: String, anchor: String?, alias: String?, isEmbed: Bool, range: NSRange, line: Int) {
        self.target = target
        self.anchor = anchor
        self.alias = alias
        self.isEmbed = isEmbed
        self.range = range
        self.line = line
    }

    public var displayText: String {
        if let alias, !alias.isEmpty { return alias }
        switch (target.isEmpty, anchor) {
        case (true, let anchor?): return anchor
        case (false, let anchor?): return "\(target) › \(anchor)"
        default: return target
        }
    }
}

/// `$行内公式$`、`$$独立公式$$`。
public struct MathSpan: Hashable, Sendable {
    public var tex: String
    public var isDisplay: Bool
    public var range: NSRange
    public var line: Int

    public init(tex: String, isDisplay: Bool, range: NSRange, line: Int) {
        self.tex = tex
        self.isDisplay = isDisplay
        self.range = range
        self.line = line
    }
}

/// 扫描 CommonMark 之外的扩展语法（双链、数学公式）。
///
/// 代码块、行内代码与 Front Matter 中的内容一律忽略。公式定界规则与 Pandoc 一致：
/// 开头 `$` 后不能是空白，结尾 `$` 前不能是空白、后面不能紧跟数字，因此 “$5 和 $10” 不会被识别为公式。
public enum MarkdownExtensionScanner {
    public struct Result: Sendable {
        public var wikiLinks: [WikiLink] = []
        public var math: [MathSpan] = []
    }

    public static func scan(_ text: String) -> Result {
        var scanner = Scanner(units: Array(text.utf16))
        scanner.run()
        return scanner.result
    }

    /// 只提取双链（反向链接索引使用）。
    public static func wikiLinks(in text: String) -> [WikiLink] {
        scan(text).wikiLinks
    }
}

private struct Scanner {
    let units: [UInt16]
    var result = MarkdownExtensionScanner.Result()

    private static let newline: UInt16 = 0x0A
    private static let backtick: UInt16 = 0x60
    private static let dollar: UInt16 = 0x24
    private static let backslash: UInt16 = 0x5C
    private static let bracketOpen: UInt16 = 0x5B
    private static let bracketClose: UInt16 = 0x5D
    private static let bang: UInt16 = 0x21
    private static let space: UInt16 = 0x20
    private static let tab: UInt16 = 0x09

    init(units: [UInt16]) {
        self.units = units
    }

    mutating func run() {
        var lineStart = 0
        var lineNumber = 1
        var fence: MarkdownFence?
        var inFrontMatter = false
        var displayMath: (start: Int, line: Int)?

        while lineStart <= units.count {
            var lineEnd = lineStart
            while lineEnd < units.count, units[lineEnd] != Self.newline { lineEnd += 1 }
            defer {
                lineStart = lineEnd + 1
                lineNumber += 1
            }

            if lineNumber == 1, isDelimiter(lineStart, lineEnd, "---"), hasFrontMatterClosing(after: lineEnd) {
                inFrontMatter = true
                if lineEnd >= units.count { break }
                continue
            }
            if inFrontMatter {
                if isDelimiter(lineStart, lineEnd, "---") || isDelimiter(lineStart, lineEnd, "...") { inFrontMatter = false }
                if lineEnd >= units.count { break }
                continue
            }

            if let open = displayMath {
                if trimmedHasSuffix(lineStart, lineEnd, "$$") {
                    let texStart = texStartAfterOpening(open.start)
                    let closing = lastIndex(of: Self.dollar, lineStart, lineEnd)! - 1
                    let tex = string(texStart, max(texStart, closing)).trimmingCharacters(in: .whitespacesAndNewlines)
                    result.math.append(MathSpan(tex: tex, isDisplay: true, range: NSRange(location: open.start, length: closing + 2 - open.start), line: open.line))
                    displayMath = nil
                }
                if lineEnd >= units.count { break }
                continue
            }

            if let open = fence {
                if let marker = MarkdownFence.parse(units, lineStart, lineEnd), open.isClosed(by: marker) {
                    fence = nil
                }
                if lineEnd >= units.count { break }
                continue
            }
            if let marker = MarkdownFence.parse(units, lineStart, lineEnd) {
                fence = marker
                if lineEnd >= units.count { break }
                continue
            }

            // 独立一行以 `$$` 开头、本行没有闭合：多行公式块。
            let first = firstNonSpace(lineStart, lineEnd)
            if first + 1 < lineEnd, units[first] == Self.dollar, units[first + 1] == Self.dollar, !hasClosingDisplay(after: first + 2, lineEnd) {
                displayMath = (first, lineNumber)
                if lineEnd >= units.count { break }
                continue
            }

            scanInline(lineStart, lineEnd, line: lineNumber)
            if lineEnd >= units.count { break }
        }
    }

    // MARK: Inline

    private mutating func scanInline(_ start: Int, _ end: Int, line: Int) {
        var index = start
        while index < end {
            let unit = units[index]
            switch unit {
            case Self.backslash:
                index += 2
            case Self.backtick:
                let run = runLength(index, end, Self.backtick)
                if let close = closingBacktickRun(length: run, from: index + run, end: end) {
                    index = close + run
                } else {
                    index += run
                }
            case Self.bracketOpen where index + 1 < end && units[index + 1] == Self.bracketOpen:
                let isEmbed = index > start && units[index - 1] == Self.bang
                if let link = wikiLink(at: index, end: end, isEmbed: isEmbed, line: line) {
                    result.wikiLinks.append(link)
                    index = NSMaxRange(link.range)
                } else {
                    index += 2
                }
            case Self.dollar:
                if let span = math(at: index, end: end, line: line) {
                    result.math.append(span)
                    index = NSMaxRange(span.range)
                } else {
                    index += runLength(index, end, Self.dollar)
                }
            default:
                index += 1
            }
        }
    }

    private func wikiLink(at open: Int, end: Int, isEmbed: Bool, line: Int) -> WikiLink? {
        var index = open + 2
        while index + 1 < end {
            let unit = units[index]
            if unit == Self.bracketOpen { return nil }
            if unit == Self.bracketClose {
                guard units[index + 1] == Self.bracketClose else { return nil }
                let inner = string(open + 2, index)
                guard !inner.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                var targetPart = inner
                var alias: String?
                if let bar = inner.firstIndex(of: "|") {
                    targetPart = String(inner[..<bar])
                    alias = String(inner[inner.index(after: bar)...]).trimmingCharacters(in: .whitespaces)
                }
                var target = targetPart
                var anchor: String?
                if let hash = targetPart.firstIndex(of: "#") {
                    target = String(targetPart[..<hash])
                    anchor = String(targetPart[targetPart.index(after: hash)...]).trimmingCharacters(in: .whitespaces)
                }
                let location = isEmbed ? open - 1 : open
                return WikiLink(
                    target: target.trimmingCharacters(in: .whitespaces),
                    anchor: anchor?.isEmpty == true ? nil : anchor,
                    alias: alias?.isEmpty == true ? nil : alias,
                    isEmbed: isEmbed,
                    range: NSRange(location: location, length: index + 2 - location),
                    line: line
                )
            }
            index += 1
        }
        return nil
    }

    /// `scanInline` 已经跳过了转义字符，这里不必再看前一个字符（`\\$x$` 中的 `$` 前是字面反斜杠）。
    private func math(at open: Int, end: Int, line: Int) -> MathSpan? {
        let isDisplay = open + 1 < end && units[open + 1] == Self.dollar
        let delimiter = isDisplay ? 2 : 1
        let contentStart = open + delimiter
        guard contentStart < end, !isWhitespace(units[contentStart]), units[contentStart] != Self.dollar else { return nil }

        var index = contentStart
        while index < end {
            let unit = units[index]
            if unit == Self.backslash {
                index += 2
                continue
            }
            if unit == Self.dollar {
                if isDisplay {
                    guard index + 1 < end, units[index + 1] == Self.dollar else { return nil }
                    let tex = string(contentStart, index).trimmingCharacters(in: .whitespaces)
                    return MathSpan(tex: tex, isDisplay: true, range: NSRange(location: open, length: index + 2 - open), line: line)
                }
                let before = units[index - 1]
                let after: UInt16? = index + 1 < end ? units[index + 1] : nil
                if isWhitespace(before) || after.map(isDigit) == true {
                    return nil
                }
                return MathSpan(tex: string(contentStart, index), isDisplay: false, range: NSRange(location: open, length: index + 1 - open), line: line)
            }
            index += 1
        }
        return nil
    }

    // MARK: Helpers

    private func string(_ start: Int, _ end: Int) -> String {
        String(decoding: units[start..<end], as: UTF16.self)
    }

    private func isWhitespace(_ unit: UInt16) -> Bool {
        unit == Self.space || unit == Self.tab || unit == Self.newline || unit == 0x3000 || unit == 0xA0
    }

    private func isDigit(_ unit: UInt16) -> Bool {
        (0x30...0x39).contains(unit)
    }

    private func runLength(_ index: Int, _ end: Int, _ unit: UInt16) -> Int {
        var cursor = index
        while cursor < end, units[cursor] == unit { cursor += 1 }
        return cursor - index
    }

    private func closingBacktickRun(length: Int, from start: Int, end: Int) -> Int? {
        var index = start
        while index < end {
            if units[index] == Self.backtick {
                let run = runLength(index, end, Self.backtick)
                if run == length { return index }
                index += run
            } else {
                index += 1
            }
        }
        return nil
    }

    private func firstNonSpace(_ start: Int, _ end: Int) -> Int {
        var index = start
        while index < end, units[index] == Self.space || units[index] == Self.tab { index += 1 }
        return index
    }

    private func lastIndex(of unit: UInt16, _ start: Int, _ end: Int) -> Int? {
        var index = end - 1
        while index >= start {
            if units[index] == unit { return index }
            index -= 1
        }
        return nil
    }

    private func trimmedHasSuffix(_ start: Int, _ end: Int, _ suffix: String) -> Bool {
        var last = end
        while last > start, units[last - 1] == Self.space || units[last - 1] == Self.tab { last -= 1 }
        let suffixUnits = Array(suffix.utf16)
        guard last - start >= suffixUnits.count else { return false }
        return Array(units[(last - suffixUnits.count)..<last]) == suffixUnits
    }

    private func hasClosingDisplay(after start: Int, _ end: Int) -> Bool {
        var index = start
        while index + 1 < end {
            if units[index] == Self.dollar, units[index + 1] == Self.dollar { return true }
            index += 1
        }
        return false
    }

    private func hasFrontMatterClosing(after firstLineEnd: Int) -> Bool {
        var start = firstLineEnd + 1
        while start < units.count {
            var end = start
            while end < units.count, units[end] != Self.newline { end += 1 }
            if isDelimiter(start, end, "---") || isDelimiter(start, end, "...") { return true }
            start = end + 1
        }
        return false
    }

    private func texStartAfterOpening(_ open: Int) -> Int {
        open + 2
    }

    private func isDelimiter(_ start: Int, _ end: Int, _ delimiter: String) -> Bool {
        var last = end
        while last > start, units[last - 1] == Self.space || units[last - 1] == Self.tab { last -= 1 }
        return Array(units[start..<last]) == Array(delimiter.utf16)
    }
}
