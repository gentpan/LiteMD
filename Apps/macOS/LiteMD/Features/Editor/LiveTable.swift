import AppKit

/// 实时预览中的 GFM 表格。只改显示属性，正文字符不变；光标进入表格时整张表回到源码。
/// - 放得下时：隐藏 `|`、首尾空白与分隔行，用字距把各列对齐，表格线与表头底色由 `LiveLayoutFragment` 绘制，
///   文字仍是正文的一部分；
/// - 放不下时：按可用宽度分配列宽，整张表画成一块（`LiveTableBlock`），单元格内自动换行，正文全部隐藏。
@MainActor
struct LiveTableLayout {
    private enum Alignment {
        case left
        case center
        case right
    }

    private static let pipe: unichar = 0x7C
    private static let backslash: unichar = 0x5C
    private static let cellPadding = Space.s3
    private static let minimumContentWidth = Space.s4
    /// 换行排版时每列内容的最小宽度；列太多连这个宽度都给不了时保持源码样式。
    private static let minimumWrappedWidth = Space.s8

    let styler: SyntaxStyler

    /// `lines` 为整张表的各行（含换行符），第一行是表头，第二行是分隔行。
    /// 分隔行不合法，或列太多、换行后仍放不进 `maximumWidth` 时不做处理，返回 false，表格保持源码样式。
    @discardableResult
    func apply(lines: [NSRange], storage: NSTextStorage, string: NSString, maximumWidth: CGFloat) -> Bool {
        guard lines.count >= 2,
              let alignments = Self.alignments(ofDelimiterRow: Self.contentRange(of: lines[1], in: string), in: string) else { return false }

        let rows = lines.enumerated().compactMap { index, line -> (line: NSRange, cells: [NSRange])? in
            index == 1 ? nil : (line, Self.cells(in: Self.contentRange(of: line, in: string), string: string))
        }
        let columnCount = max(alignments.count, rows.map(\.cells.count).max() ?? 0)

        // 先在副本上按最终样式测量，确认放得下再修改属性。
        let widths = rows.enumerated().map { index, row in
            row.cells.map { cell -> CGFloat in
                guard cell.length > 0 else { return 0 }
                let text = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: cell))
                styleCell(NSRange(location: 0, length: text.length), in: text, isHeader: index == 0)
                return text.size().width
            }
        }
        let natural = (0..<columnCount).map { column in
            max(widths.map { column < $0.count ? $0[column] : 0 }.max() ?? 0, Self.minimumContentWidth).rounded(.up)
        }
        var edges: [CGFloat] = [0]
        for width in natural {
            edges.append(edges[edges.count - 1] + width + Self.cellPadding * 2)
        }
        guard let total = edges.last, total <= maximumWidth else {
            return applyWrapped(lines: lines, rows: rows, alignments: alignments, natural: natural, storage: storage, maximumWidth: maximumWidth)
        }

        for (index, row) in rows.enumerated() {
            let isHeader = index == 0
            for cell in row.cells where cell.length > 0 {
                styleCell(cell, in: storage, isHeader: isHeader)
            }

            var firstIndent: CGFloat = 0
            var previousEnd: CGFloat?
            var visible = row.line.location
            for (column, cell) in row.cells.enumerated() where cell.length > 0 {
                let alignment = column < alignments.count ? alignments[column] : .left
                let width = widths[index][column]
                let room = edges[column + 1] - edges[column] - Self.cellPadding * 2
                let offset: CGFloat = switch alignment {
                case .left: 0
                case .center: ((room - width) / 2).rounded()
                case .right: room - width
                }
                let x = edges[column] + Self.cellPadding + offset
                hide(NSRange(location: visible, length: cell.location - visible), in: storage)
                if let previousEnd {
                    // 上一格末尾到这一格开头之间至少有一个 `|`，把间距加在最后一个隐藏字符上。
                    storage.addAttribute(.kern, value: x - previousEnd, range: NSRange(location: cell.location - 1, length: 1))
                } else {
                    firstIndent = x
                }
                previousEnd = x + width
                visible = NSMaxRange(cell)
            }
            let contentEnd = NSMaxRange(Self.contentRange(of: row.line, in: string))
            hide(NSRange(location: visible, length: contentEnd - visible), in: storage)

            let paragraph = rowParagraphStyle()
            paragraph.firstLineHeadIndent = firstIndent
            paragraph.headIndent = firstIndent
            let decoration = LiveDecoration(kind: isHeader ? .tableHeader : .tableRow, columnEdges: edges)
            storage.addAttributes([.liveDecoration: decoration, .paragraphStyle: paragraph], range: row.line)
        }

        // 分隔行整行隐藏并压成 1pt 高，只画竖线，表头与正文之间不留缝。
        let delimiter = rowParagraphStyle()
        delimiter.paragraphSpacingBefore = 0
        delimiter.paragraphSpacing = 0
        delimiter.minimumLineHeight = 1
        delimiter.maximumLineHeight = 1
        hide(lines[1], in: storage)
        storage.addAttributes([.liveDecoration: LiveDecoration(kind: .tableDelimiter, columnEdges: edges), .paragraphStyle: delimiter], range: lines[1])
        return true
    }

    /// 换行排版：列宽按内容分配，整张表的高度撑在第一行上，其余各行压扁。
    private func applyWrapped(lines: [NSRange], rows: [(line: NSRange, cells: [NSRange])], alignments: [Alignment],
                              natural: [CGFloat], storage: NSTextStorage, maximumWidth: CGFloat) -> Bool {
        let padding = Self.cellPadding * 2
        guard let contentWidths = Self.fitted(natural, into: maximumWidth - CGFloat(natural.count) * padding) else { return false }
        var columnEdges: [CGFloat] = [0]
        for width in contentWidths {
            columnEdges.append(columnEdges[columnEdges.count - 1] + width + padding)
        }

        let font = styler.baseFont
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
        var rowEdges: [CGFloat] = [0]
        var cells: [LiveTableBlock.Cell] = []
        for (index, row) in rows.enumerated() {
            let top = rowEdges[rowEdges.count - 1]
            var rowHeight = lineHeight
            for (column, cell) in row.cells.enumerated() where cell.length > 0 {
                let alignment = column < alignments.count ? alignments[column] : .left
                let text = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: cell))
                let whole = NSRange(location: 0, length: text.length)
                styleCell(whole, in: text, isHeader: index == 0)
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = switch alignment {
                case .left: .left
                case .center: .center
                case .right: .right
                }
                paragraph.lineBreakMode = .byWordWrapping
                paragraph.lineSpacing = Space.s1
                text.addAttribute(.paragraphStyle, value: paragraph, range: whole)

                let width = contentWidths[column]
                let height = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading]).height.rounded(.up)
                rowHeight = max(rowHeight, height)
                cells.append(LiveTableBlock.Cell(text: text, frame: CGRect(x: columnEdges[column] + Self.cellPadding, y: top + Space.s2, width: width, height: height)))
            }
            rowEdges.append(top + rowHeight + Space.s2 * 2)
        }
        let block = LiveTableBlock(columnEdges: columnEdges, rowEdges: rowEdges, cells: cells)

        let base = styler.base[.paragraphStyle] as? NSParagraphStyle ?? NSParagraphStyle()
        let first = base.mutableCopy() as! NSMutableParagraphStyle
        first.lineHeightMultiple = 1
        first.firstLineHeadIndent = 0
        first.headIndent = 0
        first.paragraphSpacingBefore = 0
        first.paragraphSpacing = 0
        first.minimumLineHeight = block.size.height
        first.maximumLineHeight = block.size.height
        let collapsed = first.mutableCopy() as! NSMutableParagraphStyle
        // maximumLineHeight 为 0 表示不限制，只能取一个极小值。
        collapsed.minimumLineHeight = 0
        collapsed.maximumLineHeight = 0.01

        for (index, line) in lines.enumerated() {
            hide(line, in: storage)
            storage.addAttribute(.paragraphStyle, value: index == 0 ? first : collapsed, range: line)
        }
        storage.addAttribute(.liveDecoration, value: LiveDecoration(kind: .tableBlock, tableBlock: block), range: lines[0])
        return true
    }

    /// 内容总宽超出时：不超过平均份额的列保持原宽，其余列按原宽比例分剩下的宽度。
    /// 列太多、每列连最小宽度都分不到时返回 nil。
    private static func fitted(_ natural: [CGFloat], into available: CGFloat) -> [CGFloat]? {
        guard !natural.isEmpty, CGFloat(natural.count) * minimumWrappedWidth <= available else { return nil }
        var result = natural
        var flexible = Set(natural.indices)
        var remaining = available
        while !flexible.isEmpty {
            let share = remaining / CGFloat(flexible.count)
            let fixed = flexible.filter { natural[$0] <= share }
            guard !fixed.isEmpty else { break }
            for index in fixed {
                remaining -= natural[index]
                flexible.remove(index)
            }
        }
        let flexibleTotal = flexible.reduce(0) { $0 + natural[$1] }
        for index in flexible {
            result[index] = max(minimumWrappedWidth, (remaining * natural[index] / flexibleTotal).rounded(.down))
        }
        return result.reduce(0, +) <= available ? result : nil
    }

    /// 单元格上下各留 `Space.s2`。行高倍数会把多出的空间都加在文字上方，表格行改用 1 倍，
    /// 文字才能垂直居中；整行被隐藏（全是空单元格）时仍保持正文行高。
    private func rowParagraphStyle() -> NSMutableParagraphStyle {
        let base = styler.base[.paragraphStyle] as? NSParagraphStyle ?? NSParagraphStyle()
        let paragraph = base.mutableCopy() as! NSMutableParagraphStyle
        paragraph.lineHeightMultiple = 1
        paragraph.paragraphSpacingBefore = Space.s2
        paragraph.paragraphSpacing = Space.s2
        let font = styler.baseFont
        paragraph.minimumLineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
        return paragraph
    }

    /// 表头逐段加粗（保留行内代码等其他字体，隐藏的标记不动）；`\|` 只显示竖线。
    private func styleCell(_ range: NSRange, in text: NSMutableAttributedString, isHeader: Bool) {
        if isHeader {
            text.enumerateAttribute(.font, in: range) { value, run, _ in
                guard let font = value as? NSFont, font.pointSize >= 1 else { return }
                text.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: run)
            }
        }
        let string = text.string as NSString
        var index = range.location
        while index + 1 < NSMaxRange(range) {
            if string.character(at: index) == Self.backslash {
                if string.character(at: index + 1) == Self.pipe {
                    hide(NSRange(location: index, length: 1), in: text)
                }
                index += 2
            } else {
                index += 1
            }
        }
    }

    private func hide(_ range: NSRange, in text: NSMutableAttributedString) {
        guard range.length > 0 else { return }
        text.addAttributes(styler.hiddenAttributes, range: range)
    }

    // MARK: Parsing

    /// 不含行尾换行符的部分。
    private static func contentRange(of line: NSRange, in string: NSString) -> NSRange {
        var end = NSMaxRange(line)
        while end > line.location, [0x0A, 0x0D].contains(string.character(at: end - 1)) { end -= 1 }
        return NSRange(location: line.location, length: end - line.location)
    }

    /// 按未转义的 `|` 切分，去掉行首行尾 `|` 外侧的空段，单元格去掉首尾空白。
    /// 与 GFM 一致，行内代码里的 `|` 也会切分单元格。
    private static func cells(in line: NSRange, string: NSString) -> [NSRange] {
        var segments: [NSRange] = []
        var start = line.location
        var index = line.location
        let end = NSMaxRange(line)
        while index < end {
            let unit = string.character(at: index)
            if unit == backslash {
                index += 2
                continue
            }
            if unit == pipe {
                segments.append(NSRange(location: start, length: index - start))
                start = index + 1
            }
            index += 1
        }
        segments.append(NSRange(location: start, length: end - start))
        segments = segments.map { trimmed($0, in: string) }
        if segments.count > 1, segments[0].length == 0 { segments.removeFirst() }
        if segments.count > 1, segments[segments.count - 1].length == 0 { segments.removeLast() }
        return segments
    }

    private static func trimmed(_ range: NSRange, in string: NSString) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        while start < end, [0x20, 0x09].contains(string.character(at: start)) { start += 1 }
        while end > start, [0x20, 0x09].contains(string.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// 分隔行每格必须是 `:?-+:?`。
    private static func alignments(ofDelimiterRow line: NSRange, in string: NSString) -> [Alignment]? {
        let cells = cells(in: line, string: string)
        var result: [Alignment] = []
        for cell in cells {
            let text = string.substring(with: cell)
            let leading = text.hasPrefix(":")
            let trailing = text.hasSuffix(":") && text.count > 1
            let dashes = text.dropFirst(leading ? 1 : 0).dropLast(trailing ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            result.append(leading && trailing ? .center : trailing ? .right : .left)
        }
        return result.isEmpty ? nil : result
    }
}

/// 换行排版的整张表：各单元格的文字与位置（相对表格左上角）。
final class LiveTableBlock: @unchecked Sendable {
    struct Cell {
        let text: NSAttributedString
        let frame: CGRect
    }

    /// 列边界，第一个为 0，最后一个为表格总宽。
    let columnEdges: [CGFloat]
    /// 行边界，第一个为 0，最后一个为表格总高；第一行是表头。
    let rowEdges: [CGFloat]
    let cells: [Cell]

    var size: CGSize {
        CGSize(width: columnEdges.last ?? 0, height: rowEdges.last ?? 0)
    }

    init(columnEdges: [CGFloat], rowEdges: [CGFloat], cells: [Cell]) {
        self.columnEdges = columnEdges
        self.rowEdges = rowEdges
        self.cells = cells
    }
}
