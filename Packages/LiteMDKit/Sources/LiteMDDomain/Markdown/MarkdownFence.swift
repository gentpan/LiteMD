import Foundation

/// 围栏代码块的标记行（CommonMark 4.5）。
///
/// 编辑命令、语法高亮与扩展语法扫描都要判断“哪里是代码块”，三处共用这一份规则，
/// 否则同一段文字会出现高亮是正文、Preview 却当成代码的情况。
public struct MarkdownFence: Equatable, Sendable {
    /// `` ` `` 或 `~`。
    public var character: UInt16
    public var length: Int
    /// 标记之后只有空白（只有这样的行才能闭合代码块）。
    public var infoIsEmpty: Bool

    public init(character: UInt16, length: Int, infoIsEmpty: Bool) {
        self.character = character
        self.length = length
        self.infoIsEmpty = infoIsEmpty
    }

    private static let backtick: UInt16 = 0x60
    private static let tilde: UInt16 = 0x7E

    /// 识别 `units[start..<end]` 这一行（不含换行）。行首最多 3 个空格；
    /// 反引号围栏的 info string 不能再含反引号，否则那是行内代码（例如 ```` ```ls``` 命令 ````）。
    public static func parse(_ units: [UInt16], _ start: Int, _ end: Int) -> MarkdownFence? {
        var index = start
        var spaces = 0
        while index < end, units[index] == 0x20, spaces < 3 {
            index += 1
            spaces += 1
        }
        guard index < end, units[index] == backtick || units[index] == tilde else { return nil }
        let character = units[index]
        var length = 0
        while index < end, units[index] == character {
            length += 1
            index += 1
        }
        guard length >= 3 else { return nil }
        var infoIsEmpty = true
        while index < end {
            let unit = units[index]
            if unit != 0x20, unit != 0x09 { infoIsEmpty = false }
            if character == backtick, unit == backtick { return nil }
            index += 1
        }
        return MarkdownFence(character: character, length: length, infoIsEmpty: infoIsEmpty)
    }

    /// `line` 能否闭合由 `self` 打开的代码块：同一种字符、不短于开始标记、后面没有 info string。
    public func isClosed(by line: MarkdownFence) -> Bool {
        line.character == character && line.length >= length && line.infoIsEmpty
    }
}
