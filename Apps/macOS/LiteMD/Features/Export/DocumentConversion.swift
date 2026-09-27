import AppKit
import LiteMDConversion
import LiteMDDomain
import LiteMDMarkdown
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// 导出格式（spec §35）。全部由 LiteMD 内置实现，不需要安装任何外部工具。
enum ExportFormat: String, CaseIterable, Identifiable {
    case html
    case pdf
    case docx
    case epub
    case rtf
    case odt
    case latex
    case plainText

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .html: String(localized: "HTML…")
        case .pdf: String(localized: "PDF…")
        case .docx: String(localized: "Word Document…")
        case .epub: String(localized: "EPUB…")
        case .rtf: String(localized: "Rich Text…")
        case .odt: String(localized: "OpenDocument Text…")
        case .latex: String(localized: "LaTeX…")
        case .plainText: String(localized: "Plain Text…")
        }
    }

    var fileExtension: String {
        switch self {
        case .html: "html"
        case .pdf: "pdf"
        case .docx: "docx"
        case .epub: "epub"
        case .rtf: "rtf"
        case .odt: "odt"
        case .latex: "tex"
        case .plainText: "txt"
        }
    }

    var contentType: UTType {
        switch self {
        case .html: .html
        case .pdf: .pdf
        case .docx: UTType("org.openxmlformats.wordprocessingml.document") ?? .data
        case .epub: .epub
        case .rtf: .rtf
        case .odt: UTType("org.oasis-open.opendocument.text") ?? .data
        case .latex: UTType("org.tug.tex") ?? .plainText
        case .plainText: .plainText
        }
    }
}

/// 导出格式子菜单：文件菜单、侧栏与标签页的右键菜单共用。
struct ExportFormatMenu: View {
    let title: LocalizedStringKey
    let action: (ExportFormat) -> Void

    init(_ title: LocalizedStringKey, action: @escaping (ExportFormat) -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Menu(title) {
            ForEach(ExportFormat.allCases) { format in
                Button(format.displayName) { action(format) }
            }
        }
    }
}

/// 导入 / 导出。转换本身只读取文档内容，不修改用户的 Markdown 文件。
@MainActor
final class DocumentConversion {
    private let parser = MarkdownParser()
    /// 离屏 WebView 所在的窗口，按 WebView 分开保存：批量导出 PDF 时再按 ⌥⌘P 打印，
    /// 两个任务各用各的窗口，不能互相覆盖、提前拆掉对方的。
    private var offscreenWindows: [ObjectIdentifier: NSWindow] = [:]

    // MARK: Export

    func export(markdown: String, title: String, documentDirectory: URL, format: ExportFormat, to destination: URL) async throws {
        let options = ExportOptions(title: title, documentDirectory: documentDirectory, language: Self.languageTag)
        switch format {
        case .plainText:
            try write(Data(parser.plainText(from: markdown).utf8), to: destination)
        case .html:
            let html = standaloneHTML(markdown: markdown, title: title, documentDirectory: documentDirectory)
            try write(Data(html.utf8), to: destination)
        case .pdf:
            try await exportPDF(markdown: markdown, title: title, documentDirectory: documentDirectory, to: destination)
        case .docx:
            let data = try await Task.detached(priority: .userInitiated) {
                try DocxExporter().export(markdown, options: options)
            }.value
            try write(data, to: destination)
        case .epub:
            let stylesheet = PreviewTemplate.stylesheet + PreviewTemplate.themeStylesheet(ThemeRuntime.shared.theme)
            let data = try await Task.detached(priority: .userInitiated) {
                try EpubExporter().export(markdown, options: options, stylesheet: stylesheet)
            }.value
            try write(data, to: destination)
        case .latex:
            try write(Data(LatexExporter().export(markdown, options: options).utf8), to: destination)
        case .rtf, .odt:
            // 由 AppKit 文本系统生成：先渲染为带样式的 HTML，再转换为富文本文档。
            let html = standaloneHTML(markdown: markdown, title: title, documentDirectory: documentDirectory)
            guard let attributed = NSAttributedString(html: Data(html.utf8), options: [.characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) else {
                throw ConversionError.corrupted("Could not render the document")
            }
            let type: NSAttributedString.DocumentType = format == .rtf ? .rtf : .openDocument
            let data = try attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: type, .title: title]
            )
            try write(data, to: destination)
        }
    }

    private static var languageTag: String {
        Locale.preferredLanguages.first ?? "en"
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    /// 独立 HTML：样式内联，本地图片转为 data URI，单个文件即可分享。
    func standaloneHTML(markdown: String, title: String, documentDirectory: URL) -> String {
        let body = parser.htmlFragment(from: markdown)
        let embedded = embedLocalImages(in: body, documentDirectory: documentDirectory)
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(HTMLEscaping.attribute(title))</title>
        <style>\(PreviewTemplate.stylesheet)</style>
        <style>\(PreviewTemplate.themeStylesheet(ThemeRuntime.shared.theme))</style>
        </head>
        <body>
        <article class="markdown-body">\(embedded)</article>
        </body>
        </html>
        """
    }

    /// 把本地图片替换为 data URI（超过 8 MB 的保持原样，避免文件过大）。
    private func embedLocalImages(in html: String, documentDirectory: URL) -> String {
        guard html.contains("<img") else { return html }
        var result = ""
        var remainder = Substring(html)
        // 只改真正的 <img> 标签：代码块里的文字已经转义成 &lt;img，不会被误改成 data URI。
        while let tag = remainder.range(of: "<img") {
            result += remainder[..<tag.lowerBound]
            remainder = remainder[tag.lowerBound...]
            guard let tagEnd = remainder.firstIndex(of: ">") else { break }
            result += embedSource(in: remainder[...tagEnd], documentDirectory: documentDirectory)
            remainder = remainder[remainder.index(after: tagEnd)...]
        }
        result += remainder
        return result
    }

    private func embedSource(in tag: Substring, documentDirectory: URL) -> String {
        guard let start = tag.range(of: "src=\""),
              let end = tag[start.upperBound...].firstIndex(of: "\"") else { return String(tag) }
        let source = String(tag[start.upperBound..<end])
        guard !source.hasPrefix("data:"), !source.hasPrefix("http://"), !source.hasPrefix("https://") else { return String(tag) }

        let decoded = source.removingPercentEncoding ?? source
        let fileURL: URL
        if let url = URL(string: decoded), url.isFileURL {
            fileURL = url
        } else if decoded.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: decoded)
        } else {
            fileURL = documentDirectory.appendingPathComponent(decoded)
        }
        // 先看大小再读：超过 8 MB 的图片保持原样，避免导出文件过大，也不必整个读进内存。
        guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8 * 1024 * 1024,
              let type = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType,
              let data = try? Data(contentsOf: fileURL) else { return String(tag) }
        return String(tag[..<start.upperBound]) + "data:\(type);base64,\(data.base64EncodedString())" + String(tag[end...])
    }

    /// A4：网页按 96dpi 渲染（794×1123 像素），写进 PDF 时再缩到 72dpi 的点（595×842）。
    private static let renderPageSize = CGSize(width: 794, height: 1123)
    private static let paperSize = CGSize(width: 595, height: 842)

    private func exportPDF(markdown: String, title: String, documentDirectory: URL, to destination: URL) async throws {
        let webView = try await loadPreviewWebView(markdown: markdown, documentDirectory: documentDirectory)
        defer { teardown(webView) }
        try write(try await paginatedPDF(from: webView), to: destination)
    }

    /// 打开系统打印面板（spec §36）。先生成分页好的 PDF 再交给打印面板，
    /// 直接打印离屏 WebView 会得到写不完的空白页。
    func print(markdown: String, title: String, documentDirectory: URL) async throws {
        let webView = try await loadPreviewWebView(markdown: markdown, documentDirectory: documentDirectory)
        defer { teardown(webView) }
        let data = try await paginatedPDF(from: webView)
        guard let document = PDFDocument(data: data) else {
            throw ConversionError.corrupted("Could not render the document")
        }

        let printInfo = NSPrintInfo.shared
        printInfo.topMargin = 0
        printInfo.bottomMargin = 0
        printInfo.leftMargin = 0
        printInfo.rightMargin = 0
        guard let operation = document.printOperation(for: printInfo, scalingMode: .pageScaleDownToFit, autoRotate: false) else {
            throw ConversionError.corrupted("Could not render the document")
        }
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }

    /// 按页截取网页并拼成 A4 的 PDF。
    ///
    /// WebKit 自己的分页（`WKWebView.printOperation`）在离屏窗口里不渲染内容，会一直输出空白页，
    /// 所以这里用 `WKWebView.pdf(configuration:)` 逐段截取：先把 WebView 拉到整篇文档的高度，
    /// 再按块级元素的边界切页，避免把一段文字或一个标题从中间截断。
    private func paginatedPDF(from webView: WKWebView) async throws -> Data {
        let contentHeight = try await measure(webView, script: "document.documentElement.scrollHeight")
        // 页边距之外的区域按比例缩放：网页按 96dpi 渲染，落到纸上是 72dpi 的点。
        let margin = Space.s6
        let scale = (Self.paperSize.width - margin * 2) / Self.renderPageSize.width
        let pageHeight = (Self.paperSize.height - margin * 2) / scale

        webView.window?.setContentSize(NSSize(width: Self.renderPageSize.width, height: max(contentHeight, pageHeight)))
        webView.frame = NSRect(x: 0, y: 0, width: Self.renderPageSize.width, height: max(contentHeight, pageHeight))
        try? await Task.sleep(for: .milliseconds(200))

        let boundaries = await blockBoundaries(in: webView)
        var breaks: [CGFloat] = []
        var top: CGFloat = 0
        while top + pageHeight < contentHeight {
            // 这一页里放得下的最后一个分页点，找不到（例如一张很高的图）就按整页切。
            let limit = top + pageHeight
            breaks.append(top)
            top = boundaries.last { $0 > top + pageHeight / 4 && $0 <= limit } ?? limit
        }
        breaks.append(top)

        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else {
            throw ConversionError.corrupted("Could not render the document")
        }
        var mediaBox = CGRect(origin: .zero, size: Self.paperSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ConversionError.corrupted("Could not render the document")
        }

        for (index, start) in breaks.enumerated() {
            let end = index + 1 < breaks.count ? breaks[index + 1] : contentHeight
            let height = min(max(end - start, 1), pageHeight)
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(x: 0, y: start, width: Self.renderPageSize.width, height: height)
            let slice = try await webView.pdf(configuration: configuration)
            guard let provider = CGDataProvider(data: slice as CFData),
                  let document = CGPDFDocument(provider),
                  let page = document.page(at: 1) else { continue }

            context.beginPDFPage(nil)
            context.saveGState()
            // PDF 原点在左下角：内容不足一页时靠着上边距排。
            let drawnHeight = page.getBoxRect(.mediaBox).height * scale
            context.translateBy(x: margin, y: Self.paperSize.height - margin - drawnHeight)
            context.scaleBy(x: scale, y: scale)
            context.drawPDFPage(page)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }

    /// 可以分页的位置（文档坐标）：普通块级元素取底边，标题取顶边（标题不该单独留在页尾）。
    private func blockBoundaries(in webView: WKWebView) async -> [CGFloat] {
        let script = """
        (() => {
            const selector = "h1,h2,h3,h4,h5,h6,p,li,pre,blockquote,table,img,hr,figure,.mermaid-block";
            return Array.from(document.querySelectorAll(selector))
                .map(element => {
                    const rect = element.getBoundingClientRect();
                    const edge = /^H[1-6]$/.test(element.tagName) ? rect.top : rect.bottom;
                    return edge + window.scrollY;
                })
                .filter(value => Number.isFinite(value))
                .sort((a, b) => a - b);
        })()
        """
        let value = try? await webView.evaluateJavaScript(script)
        return (value as? [NSNumber])?.map { CGFloat($0.doubleValue) } ?? []
    }

    private func measure(_ webView: WKWebView, script: String) async throws -> CGFloat {
        let value = try? await webView.evaluateJavaScript(script)
        guard let number = value as? NSNumber, number.doubleValue > 0 else {
            throw ConversionError.corrupted("Could not render the document")
        }
        return CGFloat(number.doubleValue)
    }

    /// 离屏 WebView：打印需要视图位于窗口中。
    private func loadPreviewWebView(markdown: String, documentDirectory: URL) async throws -> WKWebView {
        let configuration = PreviewController.makeConfiguration()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 794, height: 1123), configuration: configuration)
        let delegate = LoadObserver()
        webView.navigationDelegate = delegate

        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.setIsVisible(false)
        offscreenWindows[ObjectIdentifier(webView)] = window

        let result = parser.parseSynchronously(markdown, documentID: DocumentID(), revision: 0)
        webView.loadHTMLString(
            PreviewTemplate.page(body: result.html, theme: ThemeRuntime.shared.theme, fonts: ThemeRuntime.shared.fonts),
            baseURL: AssetSchemeHandler.baseURL(for: documentDirectory)
        )
        do {
            try await delegate.waitForLoad()
        } catch {
            teardown(webView)
            throw error
        }
        await PreviewController.renderMermaid(in: webView)
        // 给排版、字体与图片解码留出时间。
        try? await Task.sleep(for: .milliseconds(300))
        return webView
    }

    private func teardown(_ webView: WKWebView) {
        offscreenWindows.removeValue(forKey: ObjectIdentifier(webView))?.contentView = nil
    }

    // MARK: Import

    /// 把其他格式转换为 Markdown。Office / EPUB / HTML / CSV 由 LiteMDConversion 处理，
    /// PDF、图片、RTF / DOC / ODT 使用系统框架。
    func importDocument(at url: URL, options: ImportOptions) async throws -> ConversionResult {
        let fileExtension = url.pathExtension.lowercased()
        if ImportFormat.format(forExtension: fileExtension) != nil {
            return try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url)
                return try DocumentImporter().convert(data, fileName: url.lastPathComponent, options: options)
            }.value
        }
        if fileExtension == "pdf" {
            return try await Task.detached(priority: .userInitiated) {
                try SystemImporters.importPDF(at: url)
            }.value
        }
        if SystemImporters.imageExtensions.contains(fileExtension) {
            return try await SystemImporters.importImage(at: url, options: options)
        }
        if AudioTranscriber.audioExtensions.contains(fileExtension) {
            return try await AudioTranscriber.transcribe(url)
        }
        if SystemImporters.richTextExtensions.contains(fileExtension) {
            return try SystemImporters.importRichText(at: url)
        }
        throw ConversionError.unsupported(fileExtension)
    }
}

/// 等待 WebView 载入完成。
private final class LoadObserver: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var finished = false
    private var failure: (any Error)?

    func waitForLoad() async throws {
        if finished { return }
        if let failure { throw failure }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        failure = error
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        failure = error
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
