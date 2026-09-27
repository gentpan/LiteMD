import Foundation

/// 导出时读取 Markdown 引用的本地图片，DOCX 与 EPUB 共用。
///
/// 支持相对文档目录的路径（可以带百分号编码）、绝对路径与 `file://` 地址；远程地址与 data URI 不读取。
struct LocalImageLoader {
    let documentDirectory: URL?

    func fileURL(for source: String) -> URL? {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("file:") {
            guard let url = URL(string: trimmed), url.isFileURL else { return nil }
            return url
        }
        guard !trimmed.contains("://"), !trimmed.lowercased().hasPrefix("data:") else { return nil }
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        if decoded.hasPrefix("/") { return URL(fileURLWithPath: decoded) }
        return documentDirectory?.appendingPathComponent(decoded)
    }

    /// 扩展名统一为小写，`jpeg` 记作 `jpg`；不在 `allowedExtensions` 里的不读取。
    func load(_ source: String, allowedExtensions: Set<String>) -> (url: URL, data: Data, fileExtension: String)? {
        guard let url = fileURL(for: source) else { return nil }
        var fileExtension = url.pathExtension.lowercased()
        if fileExtension == "jpeg" { fileExtension = "jpg" }
        guard allowedExtensions.contains(fileExtension), let data = try? Data(contentsOf: url) else { return nil }
        return (url, data, fileExtension)
    }
}
