import Foundation
import LiteMDDomain

/// Workspace 全文搜索（spec §122–124）。
///
/// MVP 使用后台文件扫描：并发上限、文件大小上限、扩展名过滤、可取消。
/// 已打开的文档使用内存中的最新内容，而不是磁盘上的旧版本。
public final class WorkspaceSearcher: Sendable {
    public struct Options: Sendable {
        public var maximumConcurrentFiles = 8
        public var maximumFileSize = 10 * 1024 * 1024
        public var maximumMatchesPerFile = 200
        public var maximumTotalMatches = 5_000

        public init() {}
    }

    private let fileSystem: any FileSystem

    public init(fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
    }

    public func search(
        _ query: SearchQuery,
        files: [URL],
        openDocuments: [URL: String],
        options: Options = Options()
    ) -> AsyncStream<FileSearchResult> {
        let fileSystem = self.fileSystem
        return AsyncStream { continuation in
            let task = Task {
                guard !query.text.isEmpty else {
                    continuation.finish()
                    return
                }
                var totalMatches = 0
                await withTaskGroup(of: FileSearchResult?.self) { group in
                    var iterator = files.makeIterator()
                    var running = 0

                    func enqueueNext(_ group: inout TaskGroup<FileSearchResult?>) {
                        guard let url = iterator.next() else { return }
                        running += 1
                        let override = openDocuments[url.standardizedFileURL]
                        group.addTask {
                            guard !Task.isCancelled else { return nil }
                            let text: String
                            if let override {
                                text = override
                            } else {
                                guard let data = try? await fileSystem.readData(at: url),
                                      data.count <= options.maximumFileSize,
                                      let decoded = try? TextCodec.decode(data) else { return nil }
                                text = decoded.text
                            }
                            let matches = Self.matches(of: query, in: text, limit: options.maximumMatchesPerFile)
                            return matches.isEmpty ? nil : FileSearchResult(url: url, matches: matches)
                        }
                    }

                    for _ in 0..<options.maximumConcurrentFiles {
                        enqueueNext(&group)
                    }
                    while running > 0, let result = await group.next() {
                        running -= 1
                        if Task.isCancelled {
                            group.cancelAll()
                            break
                        }
                        if let result {
                            continuation.yield(result)
                            totalMatches += result.matches.count
                            if totalMatches >= options.maximumTotalMatches {
                                group.cancelAll()
                                break
                            }
                        }
                        enqueueNext(&group)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 在正文中查找（纯文本，默认忽略大小写）。结果按出现顺序排列。
    public static func matches(of query: SearchQuery, in text: String, limit: Int = .max) -> [SearchMatch] {
        guard !query.text.isEmpty else { return [] }
        let string = text as NSString
        let units = Array(text.utf16)
        let options: NSString.CompareOptions = query.caseSensitive ? [] : [.caseInsensitive]

        var results: [SearchMatch] = []
        var searchRange = NSRange(location: 0, length: string.length)
        var line = 1
        var lineStart = 0
        var scanned = 0

        while searchRange.length > 0, results.count < limit {
            let found = string.range(of: query.text, options: options, range: searchRange)
            guard found.location != NSNotFound, found.length > 0 else { break }

            while scanned < found.location {
                if units[scanned] == 0x0A {
                    line += 1
                    lineStart = scanned + 1
                }
                scanned += 1
            }
            var lineEnd = found.location
            while lineEnd < units.count, units[lineEnd] != 0x0A { lineEnd += 1 }

            // 摘要：匹配前最多 40 个单位，之后最多 80 个单位，去掉行首空白。
            var snippetStart = max(lineStart, found.location - 40)
            while snippetStart < found.location, units[snippetStart] == 0x20 || units[snippetStart] == 0x09 {
                snippetStart += 1
            }
            let snippetEnd = min(lineEnd, NSMaxRange(found) + 80)
            let snippetRange = safeRange(string, NSRange(location: snippetStart, length: snippetEnd - snippetStart))
            let snippet = string.substring(with: snippetRange)
            let matchInSnippet = NSRange(location: found.location - snippetRange.location, length: found.length)

            results.append(SearchMatch(
                line: line,
                column: found.location - lineStart + 1,
                range: found,
                snippet: snippet,
                snippetMatchRange: matchInSnippet
            ))
            searchRange = NSRange(location: NSMaxRange(found), length: string.length - NSMaxRange(found))
        }
        return results
    }

    /// 按搜索的同一套规则替换（纯文本、可选区分大小写、依次不重叠），保证替换的正是搜到的那些。
    /// 返回新正文与替换次数。
    public static func replacing(_ query: SearchQuery, with replacement: String, in text: String) -> (text: String, count: Int) {
        guard !query.text.isEmpty else { return (text, 0) }
        let result = NSMutableString(string: text)
        let options: NSString.CompareOptions = query.caseSensitive ? [] : [.caseInsensitive]
        let count = result.replaceOccurrences(of: query.text, with: replacement, options: options, range: NSRange(location: 0, length: result.length))
        return (result as String, count)
    }

    /// 避免在代理对中间截断。
    private static func safeRange(_ string: NSString, _ range: NSRange) -> NSRange {
        string.rangeOfComposedCharacterSequences(for: range)
    }
}
