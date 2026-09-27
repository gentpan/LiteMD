import Foundation
import LiteMDDomain
import LiteMDEditor

/// 把 `[[目标]]` 解析为 Workspace 中的文件。
///
/// 顺序：相对 Workspace 根目录的路径 → 相对当前文档目录的路径 → 文件名（不区分大小写，
/// 优先与当前文档同目录，其次路径最短）。目标不以 Markdown / 文本扩展名结尾时按 Markdown 文件查找。
public enum WikiLinkResolver {
    /// 补全扩展名时的尝试顺序：md 优先，其余按字母顺序，保证结果确定。
    private static let documentExtensions = ["md"] + MarkdownFileType.documentExtensions.subtracting(["md"]).sorted()

    public static func resolve(_ target: String, from documentURL: URL?, root: URL?, candidates: [URL]) -> URL? {
        var cleaned = target.trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix("/") { cleaned.removeFirst() }
        guard !cleaned.isEmpty else { return documentURL }

        // `[[2024.01.05]]`、`[[README.zh]]` 中的点属于文件名，只有已知扩展名才算“已带扩展名”。
        let hasExtension = MarkdownFileType.documentExtensions.contains((cleaned as NSString).pathExtension.lowercased())
        let names = hasExtension ? [cleaned] : documentExtensions.map { "\(cleaned).\($0)" }
        let byPath = Dictionary(candidates.map { (normalize($0.standardizedFileURL.path), $0) }, uniquingKeysWith: { first, _ in first })

        for base in [root, documentURL?.deletingLastPathComponent()].compactMap({ $0 }) {
            for name in names {
                let path = normalize(base.appendingPathComponent(name).standardizedFileURL.path)
                if let match = byPath[path] { return match }
            }
        }

        let wanted = Set(names.map { normalize(($0 as NSString).lastPathComponent) })
        let directory = documentURL.map { normalize($0.deletingLastPathComponent().standardizedFileURL.path) }
        let matches = candidates.filter { wanted.contains(normalize($0.lastPathComponent)) }
        // 目标带目录（`文件夹/笔记`）时，要求路径以该目录结尾。
        let folder = (cleaned as NSString).deletingLastPathComponent
        let filtered = folder.isEmpty ? matches : matches.filter {
            normalize($0.deletingLastPathComponent().standardizedFileURL.path).hasSuffix("/" + normalize(folder))
        }
        return filtered.min { lhs, rhs in
            let lhsSame = normalize(lhs.deletingLastPathComponent().standardizedFileURL.path) == directory
            let rhsSame = normalize(rhs.deletingLastPathComponent().standardizedFileURL.path) == directory
            if lhsSame != rhsSame { return lhsSame }
            if lhs.pathComponents.count != rhs.pathComponents.count { return lhs.pathComponents.count < rhs.pathComponents.count }
            return lhs.path < rhs.path
        }
    }

    /// 新建笔记时的文件名：去掉路径分隔符等非法字符。
    public static func fileName(for target: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.newlines)
        let name = target.components(separatedBy: invalid).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Untitled" : name
    }

    static func normalize(_ string: String) -> String {
        string.precomposedStringWithCanonicalMapping.lowercased()
    }
}

/// 指向某个文件的链接（反向链接面板中的一行）。
public struct Backlink: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case wikiLink
        case markdownLink
    }

    public var sourceURL: URL
    public var line: Int
    /// 源文中的 UTF-16 区间（用于跳转后选中）。
    public var range: NSRange
    public var snippet: String
    public var kind: Kind

    public var id: String { "\(sourceURL.path)#\(range.location)" }

    public init(sourceURL: URL, line: Int, range: NSRange, snippet: String, kind: Kind) {
        self.sourceURL = sourceURL
        self.line = line
        self.range = range
        self.snippet = snippet
        self.kind = kind
    }
}

/// 在 Workspace 中查找反向链接：`[[双链]]` 与指向 `.md` 文件的相对链接。
/// 读取结果按修改时间缓存，重复打开同一文档时不会重新读取未变化的文件。
public actor BacklinkIndex {
    private struct Entry {
        var modified: Date?
        var links: [(target: String, isWiki: Bool, range: NSRange, line: Int, snippet: String)]
    }

    private let fileSystem: any FileSystem
    private var cache: [URL: Entry] = [:]

    public init(fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
    }

    public func invalidate(_ url: URL) {
        cache[url.standardizedFileURL] = nil
    }

    public func backlinks(to target: URL, root: URL?, files: [URL]) async -> [Backlink] {
        let target = target.standardizedFileURL
        var results: [Backlink] = []
        for file in files {
            if Task.isCancelled { return [] }
            let source = file.standardizedFileURL
            guard source != target, let entry = await entry(for: source) else { continue }
            for link in entry.links {
                let resolved: URL?
                if link.isWiki {
                    resolved = WikiLinkResolver.resolve(link.target, from: source, root: root, candidates: files)
                } else {
                    resolved = Self.resolveRelative(link.target, from: source)
                }
                guard resolved?.standardizedFileURL == target else { continue }
                results.append(Backlink(sourceURL: source, line: link.line, range: link.range, snippet: link.snippet, kind: link.isWiki ? .wikiLink : .markdownLink))
            }
        }
        return results.sorted {
            $0.sourceURL.path != $1.sourceURL.path ? $0.sourceURL.path.localizedStandardCompare($1.sourceURL.path) == .orderedAscending : $0.line < $1.line
        }
    }

    private func entry(for url: URL) async -> Entry? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let cached = cache[url], cached.modified == modified, modified != nil { return cached }
        guard let text = try? await fileSystem.readText(at: url).text else { return nil }
        let entry = Entry(modified: modified, links: Self.extractLinks(from: text))
        cache[url] = entry
        return entry
    }

    static func extractLinks(from text: String) -> [(target: String, isWiki: Bool, range: NSRange, line: Int, snippet: String)] {
        let string = text as NSString
        func snippet(for range: NSRange) -> String {
            let line = string.substring(with: string.lineRange(for: range)).trimmingCharacters(in: .whitespacesAndNewlines)
            return line.count > 160 ? String(line.prefix(160)) + "…" : line
        }

        var links: [(String, Bool, NSRange, Int, String)] = MarkdownExtensionScanner.wikiLinks(in: text)
            .filter { !$0.target.isEmpty }
            .map { ($0.target, true, $0.range, $0.line, snippet(for: $0.range)) }

        var lineNumber = 1
        var lineStart = 0
        while lineStart <= string.length {
            let lineRange = string.lineRange(for: NSRange(location: lineStart, length: 0))
            let line = string.substring(with: lineRange).trimmingCharacters(in: .newlines)
            for link in MarkdownLinkLocator.links(inLine: line) where link.kind == .link {
                let destination = link.destination.components(separatedBy: "#").first ?? ""
                guard !destination.isEmpty, URL(string: destination)?.scheme == nil || destination.hasPrefix("file:"),
                      MarkdownFileType.isDocument(URL(fileURLWithPath: destination.removingPercentEncoding ?? destination)) else { continue }
                let range = NSRange(location: lineRange.location + link.range.location, length: link.range.length)
                links.append((destination, false, range, lineNumber, snippet(for: range)))
            }
            guard NSMaxRange(lineRange) > lineStart, NSMaxRange(lineRange) < string.length else { break }
            lineStart = NSMaxRange(lineRange)
            lineNumber += 1
        }
        return links.sorted { $0.2.location < $1.2.location }
    }

    static func resolveRelative(_ destination: String, from source: URL) -> URL? {
        let decoded = destination.removingPercentEncoding ?? destination
        if let url = URL(string: destination), url.isFileURL { return url.standardizedFileURL }
        if decoded.hasPrefix("/") { return URL(fileURLWithPath: decoded).standardizedFileURL }
        return source.deletingLastPathComponent().appendingPathComponent(decoded).standardizedFileURL
    }
}
