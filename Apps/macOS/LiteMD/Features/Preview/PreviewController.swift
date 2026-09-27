import AppKit
import LiteMDApplication
import LiteMDDomain
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import os

private let previewLog = Logger(subsystem: "app.litemd.LiteMD", category: "Preview")

/// 为 Preview 提供本地图片。只返回图片类型，其他文件一律拒绝。
final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "litemd-asset"
    static let host = "file"
    static let fileURLPrefix = "\(scheme)://\(host)"

    private var stoppedTasks = Set<ObjectIdentifier>()

    static func baseURL(for directory: URL) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = directory.standardizedFileURL.path.hasSuffix("/")
            ? directory.standardizedFileURL.path
            : directory.standardizedFileURL.path + "/"
        return components.url
    }

    static func fileURL(from url: URL) -> URL? {
        guard url.scheme == scheme, url.host() == host else { return nil }
        return URL(fileURLWithPath: url.path(percentEncoded: false)).standardizedFileURL
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let fileURL = Self.fileURL(from: requestURL),
              MarkdownFileType.isImage(fileURL) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let identifier = ObjectIdentifier(urlSchemeTask)
        stoppedTasks.remove(identifier)

        Task { @MainActor in
            let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: fileURL) }.value
            guard !self.stoppedTasks.contains(identifier) else { return }
            guard let data else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let response = URLResponse(url: requestURL, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil)
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        stoppedTasks.insert(ObjectIdentifier(urlSchemeTask))
    }
}

/// Preview 的右键菜单只保留拷贝、查询、翻译、朗读、共享等；去掉重新载入、前进后退、
/// 在新窗口打开与下载——Preview 不是浏览器，这些操作要么无效，要么会绕过链接处理。
final class PreviewWebView: WKWebView {
    private static let removedIdentifiers: Set<String> = [
        "WKMenuItemIdentifierReload",
        "WKMenuItemIdentifierGoBack",
        "WKMenuItemIdentifierGoForward",
        "WKMenuItemIdentifierStop",
        "WKMenuItemIdentifierOpenLinkInNewWindow",
        "WKMenuItemIdentifierDownloadLinkedFile",
        "WKMenuItemIdentifierOpenImageInNewWindow",
        "WKMenuItemIdentifierDownloadImage",
        "WKMenuItemIdentifierOpenFrameInNewWindow",
        "WKMenuItemIdentifierOpenMediaInNewWindow",
        "WKMenuItemIdentifierDownloadMedia",
        "WKMenuItemIdentifierInspectElement",
    ]

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        for item in menu.items {
            if let identifier = item.identifier?.rawValue, Self.removedIdentifiers.contains(identifier) {
                menu.removeItem(item)
            }
        }
        menu.normalizeSeparators()
        super.willOpenMenu(menu, with: event)
    }
}

/// 单个共享的 WKWebView。Preview 只消费 ParseResult，不直接接触编辑器（spec §128）。
@MainActor
final class PreviewController: NSObject, WKNavigationDelegate {
    let webView: PreviewWebView
    var onLinkActivated: ((URL) -> Void)?

    private var loadedDocumentID: DocumentID?
    private var loadedBaseURL: URL?
    private var renderedHTML: String?
    private var isPageLoaded = false
    private var pendingHTML: String?
    /// 最近一次要显示的内容：网页进程崩溃后用它立即重新载入，不必等下一次编辑。
    private var lastShown: (documentID: DocumentID, html: String, baseDirectory: URL)?
    private var pendingLine: Double?
    private var theme: ColorTheme = .defaultLight
    private var fonts: PreviewTemplate.Fonts = .system
    /// 当前页面是否已经载入 Mermaid（整页重新载入后需要重新注入）。
    private var isMermaidLoaded = false

    /// 预览与打印 / 导出 PDF 共用的配置：本地资源协议、页面脚本关闭、渲染脚本注入独立 content world。
    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(AssetSchemeHandler(), forURLScheme: AssetSchemeHandler.scheme)
        configuration.setURLSchemeHandler(ResourceSchemeHandler(), forURLScheme: ResourceSchemeHandler.scheme)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        // 公式与代码高亮库先于模板脚本注入。
        for library in [PreviewLibraries.katexScript, PreviewLibraries.highlightScript] where !library.isEmpty {
            configuration.userContentController.addUserScript(WKUserScript(source: library, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        }
        configuration.userContentController.addUserScript(WKUserScript(
            source: PreviewTemplate.script,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: .defaultClient
        ))
        return configuration
    }

    /// 页面含 Mermaid 图表时注入库并等待渲染完成（打印、导出 PDF 使用）。
    static func renderMermaid(in webView: WKWebView) async {
        guard let hasMermaid = try? await webView.callAsyncJavaScript("return LiteMD.hasMermaid()", arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool,
              hasMermaid, !PreviewLibraries.mermaidScript.isEmpty else { return }
        _ = try? await webView.evaluateJavaScript(PreviewLibraries.mermaidScript, in: nil, contentWorld: .defaultClient)
        _ = try? await webView.callAsyncJavaScript("await LiteMD.renderMermaid(document)", arguments: [:], in: nil, contentWorld: .defaultClient)
    }

    override init() {
        webView = PreviewWebView(frame: .zero, configuration: Self.makeConfiguration())
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true
    }

    func show(documentID: DocumentID, html: String, baseDirectory: URL) {
        lastShown = (documentID, html, baseDirectory)
        let baseURL = AssetSchemeHandler.baseURL(for: baseDirectory)
        previewLog.debug("Preview show document=\(documentID.description, privacy: .public) htmlLength=\(html.count) frame=\(self.webView.frame.debugDescription, privacy: .public) superview=\(self.webView.superview != nil)")
        if documentID != loadedDocumentID || baseURL != loadedBaseURL {
            loadedDocumentID = documentID
            loadedBaseURL = baseURL
            renderedHTML = html
            isPageLoaded = false
            isMermaidLoaded = false
            pendingHTML = nil
            webView.loadHTMLString(PreviewTemplate.page(body: html, theme: theme, fonts: fonts), baseURL: baseURL)
            return
        }
        guard html != renderedHTML else { return }
        renderedHTML = html
        guard isPageLoaded else {
            pendingHTML = html
            return
        }
        webView.callAsyncJavaScript("LiteMD.update(html)", arguments: ["html": html], in: nil, in: .defaultClient, completionHandler: nil)
        loadMermaidIfNeeded(for: html)
        #if DEBUG
        writeDiagnosticsIfRequested()
        #endif
    }

    /// 文档第一次出现 Mermaid 图表时才注入库（约 3.5 MB），随后渲染全部图表。
    private func loadMermaidIfNeeded(for html: String) {
        guard !isMermaidLoaded, html.contains("mermaid-block"), !PreviewLibraries.mermaidScript.isEmpty else { return }
        isMermaidLoaded = true
        webView.evaluateJavaScript(PreviewLibraries.mermaidScript, in: nil, in: .defaultClient) { [weak self] result in
            if case .failure(let error) = result {
                previewLog.error("Mermaid failed to load: \(error.localizedDescription, privacy: .public)")
                return
            }
            self?.webView.callAsyncJavaScript("await LiteMD.renderMermaid(document)", arguments: [:], in: nil, in: .defaultClient, completionHandler: nil)
        }
    }

    func apply(theme newTheme: ColorTheme, fonts newFonts: PreviewTemplate.Fonts) {
        let themeChanged = newTheme != theme
        let fontsChanged = newFonts != fonts
        guard themeChanged || fontsChanged else { return }
        theme = newTheme
        fonts = newFonts
        guard isPageLoaded else { return }
        if themeChanged {
            webView.callAsyncJavaScript("LiteMD.setTheme(css)", arguments: ["css": PreviewTemplate.themeStylesheet(newTheme)], in: nil, in: .defaultClient, completionHandler: nil)
        }
        if fontsChanged {
            webView.callAsyncJavaScript("LiteMD.setFonts(css)", arguments: ["css": PreviewTemplate.fontStylesheet(newFonts)], in: nil, in: .defaultClient, completionHandler: nil)
        }
    }

    func scroll(toLine line: Double) {
        guard isPageLoaded else {
            pendingLine = line
            return
        }
        webView.callAsyncJavaScript("LiteMD.scrollToLine(line)", arguments: ["line": line], in: nil, in: .defaultClient, completionHandler: nil)
    }

    #if DEBUG
    /// 本地调试：设置环境变量 LITEMD_DEBUG_PREVIEW_DIR 后，每次渲染稳定时写出预览截图与 DOM 统计，
    /// 窗口被遮挡时也能核对渲染结果。发布版本不包含。
    private var diagnosticsTask: Task<Void, Never>?

    private func writeDiagnosticsIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["LITEMD_DEBUG_PREVIEW_DIR"] else { return }
        diagnosticsTask?.cancel()
        diagnosticsTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let script = """
            return JSON.stringify({
              katex: document.querySelectorAll('.katex').length,
              mathErrors: document.querySelectorAll('.math-error').length,
              hljs: document.querySelectorAll('pre code.hljs').length,
              hljsTokens: document.querySelectorAll('[class^="hljs-"]').length,
              mermaidBlocks: document.querySelectorAll('.mermaid-block').length,
              mermaidSVG: document.querySelectorAll('.mermaid-block svg').length,
              mermaidErrors: document.querySelectorAll('.mermaid-error').length,
              wikilinks: document.querySelectorAll('a.wikilink').length,
              mermaidLoaded: typeof mermaid !== 'undefined',
              katexLoaded: typeof katex !== 'undefined',
              hljsLoaded: typeof hljs !== 'undefined'
            });
            """
            if let stats = try? await self.webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient) as? String {
                try? Data(stats.utf8).write(to: directory.appendingPathComponent("preview-stats.json"))
            }
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            if let image = try? await self.webView.takeSnapshot(configuration: configuration),
               let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent("preview.png"))
            }
        }
    }
    #endif

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        previewLog.error("Preview navigation failed: \(error.localizedDescription, privacy: .public)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        previewLog.error("Preview provisional navigation failed: \(error.localizedDescription, privacy: .public)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        previewLog.error("Preview web content process terminated")
        loadedDocumentID = nil
        loadedBaseURL = nil
        isPageLoaded = false
        if let lastShown {
            show(documentID: lastShown.documentID, html: lastShown.html, baseDirectory: lastShown.baseDirectory)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        previewLog.debug("Preview page loaded")
        isPageLoaded = true
        webView.callAsyncJavaScript("LiteMD.setTheme(css)", arguments: ["css": PreviewTemplate.themeStylesheet(theme)], in: nil, in: .defaultClient, completionHandler: nil)
        webView.callAsyncJavaScript("LiteMD.setFonts(css)", arguments: ["css": PreviewTemplate.fontStylesheet(fonts)], in: nil, in: .defaultClient, completionHandler: nil)
        if let html = pendingHTML {
            pendingHTML = nil
            webView.callAsyncJavaScript("LiteMD.update(html)", arguments: ["html": html], in: nil, in: .defaultClient, completionHandler: nil)
        }
        if let html = renderedHTML {
            loadMermaidIfNeeded(for: html)
        }
        #if DEBUG
        writeDiagnosticsIfRequested()
        #endif
        if let line = pendingLine {
            pendingLine = nil
            scroll(toLine: line)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        previewLog.debug("Preview navigation type=\(navigationAction.navigationType.rawValue, privacy: .public) url=\(url.absoluteString, privacy: .public) base=\(self.loadedBaseURL?.absoluteString ?? "nil", privacy: .public)")

        // 模板自身的加载。
        if navigationAction.navigationType == .other, url == loadedBaseURL || url.absoluteString == "about:blank" {
            return .allow
        }

        // 页内锚点。
        if navigationAction.navigationType == .linkActivated, url.fragment != nil, let current = webView.url,
           Self.withoutFragment(url) == Self.withoutFragment(current) {
            return .allow
        }

        if navigationAction.navigationType == .linkActivated {
            onLinkActivated?(url)
        }
        // 其他导航（meta refresh、表单等）一律拒绝。
        return .cancel
    }

    private static func withoutFragment(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }
}

struct PreviewPane: NSViewRepresentable {
    let controller: PreviewController
    let documentID: DocumentID
    let html: String
    let baseDirectory: URL

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
        controller.show(documentID: documentID, html: html, baseDirectory: baseDirectory)
    }

    private func attach(to container: NSView) {
        let webView = controller.webView
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}
