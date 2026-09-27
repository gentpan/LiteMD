import Foundation

/// 导入得到的图片等资源。Markdown 中以 `assetDirectory/fileName` 引用。
public struct ConvertedAsset: Equatable, Sendable {
    public var fileName: String
    public var data: Data

    public init(fileName: String, data: Data) {
        self.fileName = fileName
        self.data = data
    }
}

public struct ConversionResult: Sendable {
    public var markdown: String
    public var assets: [ConvertedAsset]
    public var title: String?

    public init(markdown: String, assets: [ConvertedAsset] = [], title: String? = nil) {
        self.markdown = markdown
        self.assets = assets
        self.title = title
    }
}

public struct ImportOptions: Sendable {
    /// Markdown 中引用资源时使用的相对目录。
    public var assetDirectory: String
    /// 资源文件名前缀，通常为源文件名。
    public var assetPrefix: String

    public init(assetDirectory: String = "assets", assetPrefix: String = "image") {
        self.assetDirectory = assetDirectory
        self.assetPrefix = assetPrefix
    }
}

/// 收集导入过程中提取的图片，生成不重复的文件名。
final class AssetCollector {
    private let options: ImportOptions
    private(set) var assets: [ConvertedAsset] = []
    private var pathsByKey: [String: String] = [:]
    private var usedNames: Set<String> = []

    init(options: ImportOptions) {
        self.options = options
    }

    /// 返回 Markdown 中使用的相对路径。同一来源只保存一次。
    func add(_ data: Data, originalName: String, key: String) -> String {
        if let existing = pathsByKey[key] { return existing }

        var fileExtension = (originalName as NSString).pathExtension.lowercased()
        if fileExtension.isEmpty || fileExtension == "jpeg" { fileExtension = fileExtension.isEmpty ? "png" : "jpg" }
        let prefix = Self.sanitize(options.assetPrefix)

        var index = assets.count + 1
        var name = "\(prefix)-\(index).\(fileExtension)"
        while usedNames.contains(name) {
            index += 1
            name = "\(prefix)-\(index).\(fileExtension)"
        }
        usedNames.insert(name)
        assets.append(ConvertedAsset(fileName: name, data: data))

        let path = options.assetDirectory.isEmpty ? name : "\(options.assetDirectory)/\(name)"
        pathsByKey[key] = path
        return path
    }

    static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var result = ""
        for scalar in name.unicodeScalars {
            result.unicodeScalars.append(allowed.contains(scalar) ? scalar : "-")
        }
        while result.contains("--") { result = result.replacingOccurrences(of: "--", with: "-") }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? "image" : result
    }
}

/// 行内片段：导入器把源格式的文本运行映射为片段，再统一合并输出 Markdown。
public struct InlinePiece: Sendable {
    public enum Content: Sendable {
        case text(String)
        case code(String)
        /// 已经是 Markdown 的内容（图片、换行），原样输出。
        case markdown(String)
    }

    public var content: Content
    public var bold = false
    public var italic = false
    public var strikethrough = false
    public var highlight = false
    public var link: String?

    public init(content: Content, bold: Bool = false, italic: Bool = false, strikethrough: Bool = false, highlight: Bool = false, link: String? = nil) {
        self.content = content
        self.bold = bold
        self.italic = italic
        self.strikethrough = strikethrough
        self.highlight = highlight
        self.link = link
    }

    public static func text(_ value: String) -> InlinePiece { InlinePiece(content: .text(value)) }
    public static func markdown(_ value: String) -> InlinePiece { InlinePiece(content: .markdown(value)) }

    fileprivate var styleKey: String {
        "\(bold)\(italic)\(strikethrough)\(highlight)\(link ?? "")"
    }
}

public enum MarkdownComposer {
    /// 合并相同格式的相邻片段，避免产生 `**a****b**`；标记内侧不留空白。
    public static func render(_ pieces: [InlinePiece]) -> String {
        var output = ""
        var index = 0
        while index < pieces.count {
            let key = pieces[index].styleKey
            var end = index
            while end + 1 < pieces.count, pieces[end + 1].styleKey == key { end += 1 }
            output += renderGroup(Array(pieces[index...end]))
            index = end + 1
        }
        return output
    }

    private static func renderGroup(_ pieces: [InlinePiece]) -> String {
        guard let first = pieces.first else { return "" }
        var inner = ""
        for piece in pieces {
            switch piece.content {
            case .text(let text): inner += escapeInline(text)
            case .code(let code): inner += inlineCode(code)
            case .markdown(let markdown): inner += markdown
            }
        }

        let leading = String(inner.prefix(while: { $0 == " " || $0 == "\t" }))
        let trailing = String(inner.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed())
        var core = String(inner.dropFirst(leading.count).dropLast(trailing.count))
        guard !core.isEmpty else { return inner }

        var open = ""
        if first.highlight { open += "==" }
        if first.strikethrough { open += "~~" }
        if first.bold && first.italic {
            open += "***"
        } else if first.bold {
            open += "**"
        } else if first.italic {
            open += "*"
        }
        core = open + core + String(open.reversed())

        if let link = first.link, !link.isEmpty {
            core = "[\(core)](\(destination(link)))"
        }
        return leading + core + trailing
    }

    public static func inlineCode(_ code: String) -> String {
        guard !code.isEmpty else { return "" }
        var longest = 0
        var current = 0
        for character in code {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        let fence = String(repeating: "`", count: longest + 1)
        let padding = code.hasPrefix("`") || code.hasSuffix("`") ? " " : ""
        return fence + padding + code + padding + fence
    }

    public static func escapeInline(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "\\", "`", "*", "_", "[", "]", "<", "|":
                result.append("\\")
                result.append(character)
            case "\u{00A0}":
                result.append(" ")
            default:
                result.append(character)
            }
        }
        return result
    }

    /// 段落开头会被误认为 Markdown 语法的字符需要转义（`line` 已经过 `escapeInline`）。
    public static func escapeLineStart(_ line: String) -> String {
        guard let first = line.first else { return line }
        // `~~~` 会开启代码块，吞掉后面所有内容。
        if "#>-+=~".contains(first) { return "\\" + line }
        // `1.` 与 `1)` 都是有序列表。
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, let delimiter = line.dropFirst(digits.count).first, delimiter == "." || delimiter == ")" {
            return digits + "\\" + line.dropFirst(digits.count)
        }
        return line
    }

    public static func destination(_ url: String) -> String {
        url.contains(where: { $0 == " " || $0 == "(" || $0 == ")" }) ? "<\(url)>" : url
    }

    public static func table(_ rows: [[String]]) -> String {
        let width = rows.map(\.count).max() ?? 0
        guard width > 0, let header = rows.first else { return "" }

        func row(_ cells: [String]) -> String {
            let padded = cells + Array(repeating: "", count: width - cells.count)
            return "| " + padded.map { cell in
                cell.replacingOccurrences(of: "\n", with: "<br>").replacingOccurrences(of: "|", with: "\\|")
            }.joined(separator: " | ") + " |"
        }

        var lines = [row(header), "| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |"]
        lines.append(contentsOf: rows.dropFirst().map(row))
        return lines.joined(separator: "\n")
    }

    /// 连接块，去掉多余空行。
    public static func joinBlocks(_ blocks: [String]) -> String {
        blocks
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n\n") + "\n"
    }
}
