import Foundation
import LiteMDDomain

public enum HighlightKind: UInt8, Sendable, Hashable, CaseIterable {
    case heading1
    case heading2
    case heading3
    case heading4
    case heading5
    case heading6
    /// 语法标记：`#`、`**`、`>`、`` ` ``、`|` 等。
    case marker
    case strong
    case emphasis
    case strongEmphasis
    case strikethrough
    case highlight
    case inlineCode
    case codeFence
    case codeBlock
    case link
    case url
    case image
    case quote
    case listMarker
    case taskChecked
    case horizontalRule
    case table
    case frontMatter
    case html
    /// `[[双链]]`
    case wikiLink
    /// `$公式$`、`$$公式块$$`
    case math
    /// 任务列表的 `[ ]` / `[x]`
    case taskBox

    static func heading(_ level: Int) -> HighlightKind {
        switch level {
        case 1: .heading1
        case 2: .heading2
        case 3: .heading3
        case 4: .heading4
        case 5: .heading5
        default: .heading6
        }
    }
}

public struct HighlightToken: Hashable, Sendable {
    public var range: NSRange
    public var kind: HighlightKind

    public init(range: NSRange, kind: HighlightKind) {
        self.range = range
        self.kind = kind
    }
}

/// Source Mode 语法高亮（spec §49）。
///
/// 这是一个快速、容错的行扫描器，只产生显示用的区间，绝不修改正文。
/// 它不追求完整 CommonMark 语义（那是 Parser 的职责），只需在编辑时给出稳定的视觉提示。
///
/// 输出保证：
/// - 所有 token 都不跨行，便于按可见区域增量应用；
/// - 按 location 升序排列；同一位置上，外层 token 排在内层之前（后应用的覆盖先应用的）。
public struct MarkdownHighlighter: Sendable {
    /// 超过该长度的行不做行内分析，避免极端内容（例如压缩数据）拖慢编辑。
    public var maximumInlineLineLength: Int

    public init(maximumInlineLineLength: Int = 10_000) {
        self.maximumInlineLineLength = maximumInlineLineLength
    }

    public func tokens(in text: String) -> [HighlightToken] {
        var scanner = HighlightScanner(units: Array(text.utf16), maximumInlineLineLength: maximumInlineLineLength)
        scanner.scanDocument()
        return scanner.sortedTokens()
    }
}

private enum Unit {
    static let newline: UInt16 = 0x0A
    static let space: UInt16 = 0x20
    static let tab: UInt16 = 0x09
    static let hash: UInt16 = 0x23
    static let greater: UInt16 = 0x3E
    static let less: UInt16 = 0x3C
    static let backtick: UInt16 = 0x60
    static let tilde: UInt16 = 0x7E
    static let star: UInt16 = 0x2A
    static let underscore: UInt16 = 0x5F
    static let dash: UInt16 = 0x2D
    static let plus: UInt16 = 0x2B
    static let pipe: UInt16 = 0x7C
    static let colon: UInt16 = 0x3A
    static let bracketOpen: UInt16 = 0x5B
    static let bracketClose: UInt16 = 0x5D
    static let parenOpen: UInt16 = 0x28
    static let parenClose: UInt16 = 0x29
    static let bang: UInt16 = 0x21
    static let backslash: UInt16 = 0x5C
    static let equals: UInt16 = 0x3D
    static let period: UInt16 = 0x2E
    static let slash: UInt16 = 0x2F
    static let dollar: UInt16 = 0x24
}

private struct HighlightScanner {
    let units: [UInt16]
    let maximumInlineLineLength: Int
    private var tokens: [(order: Int, token: HighlightToken)] = []

    init(units: [UInt16], maximumInlineLineLength: Int) {
        self.units = units
        self.maximumInlineLineLength = maximumInlineLineLength
    }

    mutating func sortedTokens() -> [HighlightToken] {
        tokens.sort { lhs, rhs in
            if lhs.token.range.location != rhs.token.range.location {
                return lhs.token.range.location < rhs.token.range.location
            }
            return lhs.order < rhs.order
        }
        return tokens.map(\.token)
    }

    private mutating func emit(_ start: Int, _ end: Int, _ kind: HighlightKind) {
        guard end > start else { return }
        tokens.append((tokens.count, HighlightToken(range: NSRange(location: start, length: end - start), kind: kind)))
    }

    // MARK: Block level

    mutating func scanDocument() {
        var lineStart = 0
        var lineIndex = 0
        var fence: MarkdownFence?
        var inFrontMatter = false
        var inTable = false
        var inDisplayMath = false
        var previousLine: (start: Int, end: Int)?

        while true {
            var lineEnd = lineStart
            while lineEnd < units.count, units[lineEnd] != Unit.newline { lineEnd += 1 }

            if inFrontMatter {
                emit(lineStart, lineEnd, .frontMatter)
                if isFrontMatterDelimiter(lineStart, lineEnd, allowDots: true) { inFrontMatter = false }
            } else if lineIndex == 0, isFrontMatterDelimiter(lineStart, lineEnd, allowDots: false), hasClosingFrontMatter(after: lineEnd) {
                emit(lineStart, lineEnd, .frontMatter)
                inFrontMatter = true
            } else if inDisplayMath {
                emit(lineStart, lineEnd, .math)
                if trimmedEnds(lineStart, lineEnd, with: Unit.dollar, count: 2) { inDisplayMath = false }
            } else if let open = fence {
                if let marker = MarkdownFence.parse(units, lineStart, lineEnd), open.isClosed(by: marker) {
                    emit(lineStart, lineEnd, .codeFence)
                    fence = nil
                } else {
                    emit(lineStart, lineEnd, .codeBlock)
                }
            } else if let marker = MarkdownFence.parse(units, lineStart, lineEnd) {
                emit(lineStart, lineEnd, .codeFence)
                fence = marker
                inTable = false
            } else if startsDisplayMath(lineStart, lineEnd) {
                emit(lineStart, lineEnd, .math)
                inDisplayMath = true
                inTable = false
            } else if isBlank(lineStart, lineEnd) {
                inTable = false
            } else if let previous = previousLine, !inTable, isTableDelimiterRow(lineStart, lineEnd), contains(Unit.pipe, previous.start, previous.end) {
                emitPipes(previous.start, previous.end)
                emit(lineStart, lineEnd, .table)
                inTable = true
            } else if isThematicBreak(lineStart, lineEnd) {
                emit(lineStart, lineEnd, .horizontalRule)
                inTable = false
            } else {
                if inTable {
                    if contains(Unit.pipe, lineStart, lineEnd) {
                        emitPipes(lineStart, lineEnd)
                    } else {
                        inTable = false
                    }
                }
                scanContentLine(lineStart, lineEnd)
            }

            previousLine = (lineStart, lineEnd)
            guard lineEnd < units.count else { break }
            lineStart = lineEnd + 1
            lineIndex += 1
        }
    }

    private mutating func scanContentLine(_ start: Int, _ end: Int) {
        var position = start

        // 引用（可嵌套）
        var quoted = false
        while true {
            var index = position
            var spaces = 0
            while index < end, units[index] == Unit.space, spaces < 3 {
                index += 1
                spaces += 1
            }
            guard index < end, units[index] == Unit.greater else { break }
            if !quoted {
                emit(start, end, .quote)
                quoted = true
            }
            emit(index, index + 1, .marker)
            index += 1
            if index < end, units[index] == Unit.space { index += 1 }
            position = index
        }

        // ATX 标题
        if let heading = headingPrefix(position, end) {
            emit(position, end, .heading(heading.level))
            emit(heading.markerStart, heading.markerEnd, .marker)
            scanInline(heading.contentStart, end)
            return
        }

        // 列表与任务
        if let list = listPrefix(position, end) {
            emit(list.markerStart, list.markerEnd, .listMarker)
            if let box = list.taskBox {
                emit(box.start, box.end, .taskBox)
                if box.checked {
                    emit(list.contentStart, end, .taskChecked)
                }
            }
            position = list.contentStart
        }

        scanInline(position, end)
    }

    /// 以 `$$` 开头、本行没有闭合的行开始一个公式块。
    private func startsDisplayMath(_ start: Int, _ end: Int) -> Bool {
        var index = start
        while index < end, units[index] == Unit.space { index += 1 }
        guard index + 1 < end, units[index] == Unit.dollar, units[index + 1] == Unit.dollar else { return false }
        var cursor = index + 2
        while cursor + 1 < end {
            if units[cursor] == Unit.dollar, units[cursor + 1] == Unit.dollar { return false }
            cursor += 1
        }
        return true
    }

    private func trimmedEnds(_ start: Int, _ end: Int, with unit: UInt16, count: Int) -> Bool {
        var last = end
        while last > start, units[last - 1] == Unit.space || units[last - 1] == Unit.tab { last -= 1 }
        guard last - start >= count else { return false }
        return (0..<count).allSatisfy { units[last - 1 - $0] == unit }
    }

    private func isBlank(_ start: Int, _ end: Int) -> Bool {
        var index = start
        while index < end {
            if units[index] != Unit.space, units[index] != Unit.tab { return false }
            index += 1
        }
        return true
    }

    private func contains(_ unit: UInt16, _ start: Int, _ end: Int) -> Bool {
        var index = start
        while index < end {
            if units[index] == unit { return true }
            index += 1
        }
        return false
    }

    private mutating func emitPipes(_ start: Int, _ end: Int) {
        var index = start
        while index < end {
            if units[index] == Unit.backslash {
                index += 2
                continue
            }
            if units[index] == Unit.pipe { emit(index, index + 1, .table) }
            index += 1
        }
    }

    private func isFrontMatterDelimiter(_ start: Int, _ end: Int, allowDots: Bool) -> Bool {
        var index = start
        guard end - start >= 3 else { return false }
        let char = units[start]
        guard char == Unit.dash || (allowDots && char == Unit.period) else { return false }
        var count = 0
        while index < end, units[index] == char {
            count += 1
            index += 1
        }
        guard count == 3 else { return false }
        return isBlank(index, end)
    }

    private func hasClosingFrontMatter(after firstLineEnd: Int) -> Bool {
        var lineStart = firstLineEnd + 1
        while lineStart < units.count {
            var lineEnd = lineStart
            while lineEnd < units.count, units[lineEnd] != Unit.newline { lineEnd += 1 }
            if isFrontMatterDelimiter(lineStart, lineEnd, allowDots: true) { return true }
            lineStart = lineEnd + 1
        }
        return false
    }

    private func isThematicBreak(_ start: Int, _ end: Int) -> Bool {
        var index = start
        var spaces = 0
        while index < end, units[index] == Unit.space, spaces < 3 {
            index += 1
            spaces += 1
        }
        guard index < end else { return false }
        let char = units[index]
        guard char == Unit.dash || char == Unit.star || char == Unit.underscore else { return false }
        var count = 0
        while index < end {
            let unit = units[index]
            if unit == char {
                count += 1
            } else if unit != Unit.space, unit != Unit.tab {
                return false
            }
            index += 1
        }
        return count >= 3
    }

    private func isTableDelimiterRow(_ start: Int, _ end: Int) -> Bool {
        var hasDash = false
        var hasPipe = false
        var index = start
        while index < end {
            switch units[index] {
            case Unit.dash: hasDash = true
            case Unit.pipe: hasPipe = true
            case Unit.colon, Unit.space, Unit.tab: break
            default: return false
            }
            index += 1
        }
        return hasDash && hasPipe
    }

    private func headingPrefix(_ start: Int, _ end: Int) -> (level: Int, markerStart: Int, markerEnd: Int, contentStart: Int)? {
        var index = start
        var spaces = 0
        while index < end, units[index] == Unit.space, spaces < 3 {
            index += 1
            spaces += 1
        }
        let markerStart = index
        var level = 0
        while index < end, units[index] == Unit.hash {
            level += 1
            index += 1
        }
        guard (1...6).contains(level) else { return nil }
        guard index == end || units[index] == Unit.space || units[index] == Unit.tab else { return nil }
        let markerEnd = index
        while index < end, units[index] == Unit.space || units[index] == Unit.tab { index += 1 }
        return (level, markerStart, markerEnd, index)
    }

    private func listPrefix(_ start: Int, _ end: Int) -> (markerStart: Int, markerEnd: Int, contentStart: Int, taskBox: (start: Int, end: Int, checked: Bool)?)? {
        var index = start
        while index < end, units[index] == Unit.space || units[index] == Unit.tab { index += 1 }
        guard index < end else { return nil }
        let markerStart = index

        switch units[index] {
        case Unit.dash, Unit.star, Unit.plus:
            index += 1
        case 0x30...0x39:
            var digits = 0
            while index < end, (0x30...0x39).contains(units[index]), digits < 9 {
                index += 1
                digits += 1
            }
            guard index < end, units[index] == Unit.period || units[index] == Unit.parenClose else { return nil }
            index += 1
        default:
            return nil
        }

        let markerEnd = index
        guard index < end, units[index] == Unit.space || units[index] == Unit.tab else { return nil }
        while index < end, units[index] == Unit.space || units[index] == Unit.tab { index += 1 }

        var taskBox: (Int, Int, Bool)?
        if index + 2 < end,
           units[index] == Unit.bracketOpen,
           units[index + 2] == Unit.bracketClose,
           [Unit.space, 0x78, 0x58].contains(units[index + 1]),
           index + 3 == end || units[index + 3] == Unit.space || units[index + 3] == Unit.tab {
            taskBox = (index, index + 3, units[index + 1] != Unit.space)
            index += 3
            while index < end, units[index] == Unit.space || units[index] == Unit.tab { index += 1 }
        }
        return (markerStart, markerEnd, index, taskBox)
    }

    // MARK: Inline

    private mutating func scanInline(_ start: Int, _ end: Int) {
        guard end - start <= maximumInlineLineLength else { return }
        var index = start

        while index < end {
            let unit = units[index]
            switch unit {
            case Unit.backslash:
                index += 2

            case Unit.backtick:
                let run = runLength(index, end, unit)
                if let close = findClosingRun(of: unit, length: run, from: index + run, end: end, requireFlanking: false) {
                    emit(index, close + run, .inlineCode)
                    emit(index, index + run, .marker)
                    emit(close, close + run, .marker)
                    index = close + run
                } else {
                    index += run
                }

            case Unit.bang where index + 2 < end && units[index + 1] == Unit.bracketOpen && units[index + 2] == Unit.bracketOpen:
                if let next = scanWikiLink(open: index + 1, start: index, end: end) {
                    index = next
                } else {
                    index += 3
                }

            case Unit.bracketOpen where index + 1 < end && units[index + 1] == Unit.bracketOpen:
                if let next = scanWikiLink(open: index, start: index, end: end) {
                    index = next
                } else if let next = scanLink(bracket: index, end: end, isImage: false) {
                    index = next
                } else {
                    index += 1
                }

            case Unit.dollar:
                index = scanMath(index, start: start, end: end)

            case Unit.bang where index + 1 < end && units[index + 1] == Unit.bracketOpen:
                if let next = scanLink(bracket: index + 1, end: end, isImage: true) {
                    index = next
                } else {
                    index += 2
                }

            case Unit.bracketOpen:
                if let next = scanLink(bracket: index, end: end, isImage: false) {
                    index = next
                } else {
                    index += 1
                }

            case Unit.less:
                index = scanAngle(index, end)

            case Unit.star, Unit.underscore:
                index = scanEmphasis(index, end, unit)

            case Unit.tilde, Unit.equals:
                let run = runLength(index, end, unit)
                if run == 2,
                   index + 2 < end,
                   !isWhitespace(units[index + 2]),
                   let close = findClosingRun(of: unit, length: 2, from: index + 2, end: end, requireFlanking: true) {
                    emit(index, close + 2, unit == Unit.tilde ? .strikethrough : .highlight)
                    emit(index, index + 2, .marker)
                    emit(close, close + 2, .marker)
                    scanInline(index + 2, close)
                    index = close + 2
                } else {
                    index += run
                }

            case 0x68 where startsWithURLScheme(index, end) && (index == start || isURLBoundary(units[index - 1])):
                var urlEnd = index
                while urlEnd < end, !isWhitespace(units[urlEnd]), units[urlEnd] != Unit.less { urlEnd += 1 }
                while urlEnd > index, [Unit.period, 0x2C, Unit.parenClose, 0x3B, Unit.colon].contains(units[urlEnd - 1]) { urlEnd -= 1 }
                emit(index, urlEnd, .url)
                index = max(urlEnd, index + 1)

            default:
                index += 1
            }
        }
    }

    /// `[[目标|别名]]`：`[[`、`]]` 为标记，别名存在时 `目标|` 作为 url（实时预览中隐藏）。
    private mutating func scanWikiLink(open: Int, start: Int, end: Int) -> Int? {
        var index = open + 2
        var bar: Int?
        while index + 1 < end {
            let unit = units[index]
            if unit == Unit.bracketOpen { return nil }
            if unit == Unit.pipe, bar == nil { bar = index }
            if unit == Unit.bracketClose {
                guard units[index + 1] == Unit.bracketClose, index > open + 2 else { return nil }
                emit(start, index + 2, .wikiLink)
                emit(start, open + 2, .marker)
                if let bar { emit(open + 2, bar + 1, .url) }
                emit(index, index + 2, .marker)
                return index + 2
            }
            index += 1
        }
        return nil
    }

    /// 行内公式，规则与 MarkdownExtensionScanner 一致。
    private mutating func scanMath(_ index: Int, start: Int, end: Int) -> Int {
        let isDisplay = index + 1 < end && units[index + 1] == Unit.dollar
        let delimiter = isDisplay ? 2 : 1
        let contentStart = index + delimiter
        guard contentStart < end, !isWhitespace(units[contentStart]), units[contentStart] != Unit.dollar else { return index + delimiter }
        var cursor = contentStart
        while cursor < end {
            if units[cursor] == Unit.backslash {
                cursor += 2
                continue
            }
            if units[cursor] == Unit.dollar {
                if isDisplay {
                    guard cursor + 1 < end, units[cursor + 1] == Unit.dollar else { return index + delimiter }
                } else if isWhitespace(units[cursor - 1]) || (cursor + 1 < end && (0x30...0x39).contains(units[cursor + 1])) {
                    return index + delimiter
                }
                let close = cursor + delimiter
                emit(index, close, .math)
                emit(index, contentStart, .marker)
                emit(cursor, close, .marker)
                return close
            }
            cursor += 1
        }
        return index + delimiter
    }

    private mutating func scanEmphasis(_ index: Int, _ end: Int, _ unit: UInt16) -> Int {
        let run = runLength(index, end, unit)
        let after = index + run
        guard after < end, !isWhitespace(units[after]) else { return after }
        if unit == Unit.underscore, index > 0, isWordCharacter(units[index - 1]) { return after }

        let length = min(run, 3)
        guard let close = findClosingRun(of: unit, length: length, from: after, end: end, requireFlanking: true) else {
            return after
        }
        if unit == Unit.underscore, close + length < end, isWordCharacter(units[close + length]) { return after }

        let openStart = after - length
        let kind: HighlightKind = switch length {
        case 1: .emphasis
        case 2: .strong
        default: .strongEmphasis
        }
        emit(openStart, close + length, kind)
        emit(index, after, .marker)
        emit(close, close + length, .marker)
        scanInline(after, close)
        return close + length
    }

    private mutating func scanLink(bracket: Int, end: Int, isImage: Bool) -> Int? {
        guard let closeBracket = matching(open: Unit.bracketOpen, close: Unit.bracketClose, from: bracket, end: end) else { return nil }
        let start = isImage ? bracket - 1 : bracket

        if closeBracket + 1 < end, units[closeBracket + 1] == Unit.parenOpen,
           let closeParen = matching(open: Unit.parenOpen, close: Unit.parenClose, from: closeBracket + 1, end: end) {
            emit(start, closeParen + 1, isImage ? .image : .link)
            emit(start, bracket + 1, .marker)
            emit(closeBracket, closeBracket + 1, .marker)
            emit(closeBracket + 1, closeParen + 1, .url)
            if !isImage { scanInline(bracket + 1, closeBracket) }
            return closeParen + 1
        }

        // 引用式链接 [text][ref]
        if closeBracket + 1 < end, units[closeBracket + 1] == Unit.bracketOpen,
           let closeReference = matching(open: Unit.bracketOpen, close: Unit.bracketClose, from: closeBracket + 1, end: end) {
            emit(start, closeReference + 1, isImage ? .image : .link)
            emit(closeBracket + 1, closeReference + 1, .url)
            return closeReference + 1
        }

        // 链接定义 [ref]: https://...
        if !isImage, closeBracket + 1 < end, units[closeBracket + 1] == Unit.colon {
            emit(bracket, closeBracket + 1, .link)
            emit(closeBracket + 2, end, .url)
            return end
        }
        return nil
    }

    private mutating func scanAngle(_ index: Int, _ end: Int) -> Int {
        var close = index + 1
        while close < end, units[close] != Unit.greater, units[close] != Unit.less { close += 1 }
        guard close < end, units[close] == Unit.greater, close > index + 1 else { return index + 1 }

        let first = units[index + 1]
        if startsWithURLScheme(index + 1, close) || containsAt(index + 1, close) {
            emit(index, close + 1, .url)
            return close + 1
        }
        let isLetter = (0x41...0x5A).contains(first) || (0x61...0x7A).contains(first)
        if isLetter || first == Unit.slash || first == Unit.bang {
            emit(index, close + 1, .html)
            return close + 1
        }
        return index + 1
    }

    private func containsAt(_ start: Int, _ end: Int) -> Bool {
        var index = start
        while index < end {
            if units[index] == 0x40 { return !contains(Unit.space, start, end) }
            index += 1
        }
        return false
    }

    private func matching(open: UInt16, close: UInt16, from start: Int, end: Int) -> Int? {
        var depth = 0
        var index = start
        while index < end {
            let unit = units[index]
            if unit == Unit.backslash {
                index += 2
                continue
            }
            if unit == open {
                depth += 1
            } else if unit == close {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    private func runLength(_ index: Int, _ end: Int, _ unit: UInt16) -> Int {
        var cursor = index
        while cursor < end, units[cursor] == unit { cursor += 1 }
        return cursor - index
    }

    private func findClosingRun(of unit: UInt16, length: Int, from start: Int, end: Int, requireFlanking: Bool) -> Int? {
        var index = start
        while index < end {
            let current = units[index]
            if current == Unit.backslash, unit != Unit.backtick {
                index += 2
                continue
            }
            if current == unit {
                let run = runLength(index, end, unit)
                let flanking = !requireFlanking || (index > start && !isWhitespace(units[index - 1]))
                if run >= length, flanking {
                    // 例如 `**bold***`：取最靠后的 length 个作为闭合。
                    return index + run - length
                }
                index += run
                continue
            }
            if unit != Unit.backtick, current == Unit.backtick {
                // 跳过行内代码，代码里的星号不算强调。
                let run = runLength(index, end, Unit.backtick)
                if let close = findClosingRun(of: Unit.backtick, length: run, from: index + run, end: end, requireFlanking: false) {
                    index = close + run
                    continue
                }
                index += run
                continue
            }
            index += 1
        }
        return nil
    }

    private func startsWithURLScheme(_ index: Int, _ end: Int) -> Bool {
        let http: [UInt16] = Array("http://".utf16)
        let https: [UInt16] = Array("https://".utf16)
        return hasPrefix(https, at: index, end: end) || hasPrefix(http, at: index, end: end)
    }

    private func hasPrefix(_ prefix: [UInt16], at index: Int, end: Int) -> Bool {
        guard index + prefix.count <= end else { return false }
        for offset in 0..<prefix.count where units[index + offset] != prefix[offset] {
            return false
        }
        return true
    }

    private func isURLBoundary(_ unit: UInt16) -> Bool {
        isWhitespace(unit) || unit == Unit.parenOpen || unit == Unit.bracketOpen || unit >= 0x3000
    }

    private func isWhitespace(_ unit: UInt16) -> Bool {
        unit == Unit.space || unit == Unit.tab || unit == Unit.newline || unit == 0x3000 || unit == 0xA0
    }

    private func isWordCharacter(_ unit: UInt16) -> Bool {
        (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) || unit >= 0x80
    }
}
