import Foundation

/// 粘贴时把网页、Word、Google 文档等复制出来的 HTML 转成 Markdown。
///
/// 返回 nil 表示应当按纯文本粘贴：
/// - 内容来自代码编辑器（最外层元素用 `white-space: pre` 保留缩进，按 HTML 转换会把缩进压掉）；
/// - 转换结果和纯文本没有实质区别，说明原文没有格式，照原样粘贴更干净。
public enum PastedHTML {
    public static func markdown(fromHTML html: String, plainText: String?) -> String? {
        let root = HTMLTagSoupParser.parse(html)
        let body = HTMLMarkdownConverter.find(root, "body") ?? root
        if let first = body.elements.first, preservesWhitespace(first["style"]) { return nil }

        // data: 内嵌图片会在正文里塞进几十 KB 的编码，丢掉；网络图片保留原地址。
        let converter = HTMLMarkdownConverter(resolveImage: { $0.lowercased().hasPrefix("data:") ? "" : nil })
        let markdown = converter.convert(root).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else { return nil }
        if let plainText, normalized(markdown) == normalized(plainText) { return nil }
        return markdown
    }

    private static func preservesWhitespace(_ style: String?) -> Bool {
        guard let style = style?.lowercased() else { return false }
        return style.replacingOccurrences(of: " ", with: "").contains("white-space:pre")
    }

    /// 去掉 Markdown 转义与空白差异后比较：`1\.` 与 `1.`、换行与空格都视为相同。
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: #"\\([!-/:-@\[-`{-~])"#, with: "$1", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
