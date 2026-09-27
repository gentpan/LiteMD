#if DEBUG
import AppKit
import LiteMDDomain

/// 本地调试：设置 LITEMD_DEBUG_PASTE_HTML="HTML 文件|Markdown 文件|end 或 code" 后，启动时打开 Markdown 文件，
/// 把光标放到末尾（end）或第一个代码块里（code），按“粘贴”处理那段 HTML 并保存。
/// 用私有剪贴板，不碰系统剪贴板。
@MainActor
enum PasteDebugRun {
    static func runIfRequested(model: AppModel) async {
        guard let value = ProcessInfo.processInfo.environment["LITEMD_DEBUG_PASTE_HTML"] else { return }
        let parts = value.split(separator: "|").map(String.init)
        guard parts.count == 3, let html = try? String(contentsOfFile: parts[0], encoding: .utf8) else { return }
        guard let document = await model.openDocument(URL(fileURLWithPath: parts[1])) else { return }
        let editor = model.editor(for: document)
        let text = editor.textView.string as NSString
        let caret = parts[2] == "code"
            ? NSMaxRange(text.lineRange(for: NSRange(location: text.range(of: "```").location, length: 0)))
            : text.length
        editor.textView.setSelectedRange(NSRange(location: caret, length: 0))

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("LiteMD-Debug-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(html, forType: .html)
        pasteboard.setString("plain text fallback", forType: .string)
        let converted = editor.pasteRichTextAsMarkdown(from: pasteboard)
        pasteboard.releaseGlobally()
        print("[paste] converted=\(converted)")
        try? await model.documents.save(document)
        print("[paste] saved")
    }
}
#endif
