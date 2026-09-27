import Foundation

public struct HeadingItem: Identifiable, Hashable, Sendable {
    public var id: Int { index }
    public var index: Int
    public var level: Int
    public var title: String
    /// 从 1 开始的行号。
    public var line: Int
    /// 行首的 UTF-16 偏移。
    public var offset: Int
    /// Preview 中对应的锚点。
    public var anchor: String

    public init(index: Int, level: Int, title: String, line: Int, offset: Int, anchor: String) {
        self.index = index
        self.level = level
        self.title = title
        self.line = line
        self.offset = offset
        self.anchor = anchor
    }
}

public struct DocumentStatistics: Equatable, Sendable {
    public var words: Int
    public var characters: Int
    public var lines: Int
    public var readingMinutes: Int

    public init(words: Int = 0, characters: Int = 0, lines: Int = 1, readingMinutes: Int = 0) {
        self.words = words
        self.characters = characters
        self.lines = lines
        self.readingMinutes = readingMinutes
    }
}

/// Parser 输出（spec §96）。`revision` 用于丢弃过期结果。
public struct ParseResult: Sendable {
    public var documentID: DocumentID
    public var revision: Int
    public var headings: [HeadingItem]
    public var statistics: DocumentStatistics
    /// 已净化的 HTML 片段，块级元素带 `data-line` 以支持滚动同步。
    public var html: String

    public init(
        documentID: DocumentID,
        revision: Int,
        headings: [HeadingItem] = [],
        statistics: DocumentStatistics = DocumentStatistics(),
        html: String = ""
    ) {
        self.documentID = documentID
        self.revision = revision
        self.headings = headings
        self.statistics = statistics
        self.html = html
    }
}

public struct SearchQuery: Equatable, Sendable {
    public var text: String
    public var caseSensitive: Bool

    public init(text: String, caseSensitive: Bool = false) {
        self.text = text
        self.caseSensitive = caseSensitive
    }
}

public struct SearchMatch: Hashable, Sendable {
    /// 从 1 开始。
    public var line: Int
    /// 从 1 开始，UTF-16 列。
    public var column: Int
    /// 在正文（LF 统一后）中的 UTF-16 区间。
    public var range: NSRange
    public var snippet: String
    public var snippetMatchRange: NSRange

    public init(line: Int, column: Int, range: NSRange, snippet: String, snippetMatchRange: NSRange) {
        self.line = line
        self.column = column
        self.range = range
        self.snippet = snippet
        self.snippetMatchRange = snippetMatchRange
    }
}

public struct FileSearchResult: Identifiable, Hashable, Sendable {
    public var url: URL
    public var matches: [SearchMatch]

    public init(url: URL, matches: [SearchMatch]) {
        self.url = url
        self.matches = matches
    }

    public var id: URL { url }
}
