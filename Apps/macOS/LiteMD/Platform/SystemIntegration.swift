import AppKit
import LiteMDDomain
import UniformTypeIdentifiers

/// 平台能力集中在这里（spec §139）：文件面板、Finder、外部链接、剪贴板、提示框。
@MainActor
enum SystemIntegration {
    static let markdownType = UTType("net.daringfireball.markdown") ?? .plainText

    static func chooseFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [markdownType, .plainText]
        panel.message = String(localized: "Choose Markdown files to open")
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func chooseFolder(startingAt directory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if let directory { panel.directoryURL = directory }
        panel.prompt = String(localized: "Open Folder")
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseExportFolder(startingAt directory: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if let directory { panel.directoryURL = directory }
        panel.message = String(localized: "Choose where to put the exported files")
        panel.prompt = String(localized: "Export")
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseRecording() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = AudioTranscriber.audioExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = String(localized: "Choose a recording to transcribe. Recognition runs on this Mac.")
        panel.prompt = String(localized: "Transcribe")
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFonts() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.font]
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Import")
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func chooseRestoreLocation() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = String(localized: "Choose where to put the restored folder")
        panel.prompt = String(localized: "Restore Here")
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseImages() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.prompt = String(localized: "Insert")
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// 可导入的格式：Office、EPUB、HTML、CSV、PDF、图片、RTF 等（全部内置，无需额外工具）。
    static func chooseImportFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = SystemImporters.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = String(localized: "Choose files to convert to Markdown")
        panel.prompt = String(localized: "Import")
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func chooseExportLocation(suggestedName: String, format: ExportFormat, directory: URL?) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(suggestedName).\(format.fileExtension)"
        if let directory { panel.directoryURL = directory }
        panel.prompt = String(localized: "Export")
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseSaveLocation(suggestedName: String, directory: URL?) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [markdownType]
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedName.hasSuffix(".md") ? suggestedName : suggestedName + ".md"
        if let directory { panel.directoryURL = directory }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func openExternally(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// 打开文档里链接到的本地文件。链接可能来自别人写的文档：指向应用、脚本、安装包时，
    /// 直接打开等于运行它，先问一句，默认按钮是“取消”。
    static func openLocalFile(_ url: URL) {
        if isRunnable(url) {
            let choice = runAlert(
                title: String(localized: "Open “\(url.lastPathComponent)”?"),
                message: String(localized: "This link points to an app or script. Opening it will run it on your Mac."),
                buttons: [String(localized: "Cancel"), String(localized: "Open")]
            )
            guard choice == 1 else { return }
        }
        NSWorkspace.shared.open(url)
    }

    private static let runnableExtensions: Set<String> = [
        "command", "tool", "terminal", "workflow", "action", "pkg", "mpkg",
        "webloc", "inetloc", "fileloc", "jar", "prefpane", "mobileconfig",
    ]

    private static func isRunnable(_ url: URL) -> Bool {
        if runnableExtensions.contains(url.pathExtension.lowercased()) { return true }
        let values = try? url.resourceValues(forKeys: [.isApplicationKey, .isExecutableKey, .isDirectoryKey, .contentTypeKey])
        if values?.isApplication == true { return true }
        if values?.isExecutable == true, values?.isDirectory != true { return true }
        guard let type = values?.contentType else { return false }
        return [UTType.application, .executable, .script].contains { type.conforms(to: $0) }
    }

    static func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// 返回被点击按钮的序号（从 0 开始）。
    @discardableResult
    static func runAlert(title: String, message: String, buttons: [String], style: NSAlert.Style = .warning, details: String? = nil) -> Int {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        for button in buttons {
            alert.addButton(withTitle: button)
        }
        if let details, !details.isEmpty {
            let field = NSTextField(wrappingLabelWithString: details)
            field.isSelectable = true
            field.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            field.textColor = .secondaryLabelColor
            field.frame.size.width = Layout.welcomeWidth - Space.s12
            alert.accessoryView = field
        }
        let response = alert.runModal()
        return response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    /// 当前进程退出后重新打开应用；`prepared` 不为空时先用它替换当前应用包。
    ///
    /// 旧版本先移到临时目录，新版本放不进去就挪回原处；无论成功与否都会重新打开应用。
    /// 新旧两份都还在的时候（原位置已经有应用）才清理临时文件，避免把唯一的一份删掉。
    static func relaunchAfterExit(installing prepared: URL? = nil, cleaningUp workspace: URL? = nil) {
        let target = Bundle.main.bundleURL.path
        let backup = prepared == nil ? "" : FileManager.default.temporaryDirectory.appendingPathComponent("LiteMD-Previous-\(UUID().uuidString).app").path
        let script = """
        while kill -0 "$0" 2>/dev/null; do sleep 0.2; done
        if [ -n "$2" ] && mv "$1" "$3"; then
          mv "$2" "$1" || mv "$3" "$1"
        fi
        /usr/bin/open "$1"
        if [ -d "$1" ]; then
          [ -n "$3" ] && rm -rf "$3"
          [ -n "$4" ] && rm -rf "$4"
        fi
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, String(ProcessInfo.processInfo.processIdentifier), target, prepared?.path ?? "", backup, workspace?.path ?? ""]
        try? process.run()
    }

    static func present(_ error: LiteMDError) {
        runAlert(title: error.localizedTitle, message: error.localizedMessage, buttons: [String(localized: "OK")], details: error.technicalDetails)
    }

    /// 语音识别、打印、转换等不是 LiteMDError 的错误，显示它自己的说明，
    /// 不能统一套成“无法打开文档”。
    static func present(_ error: any Error, title: String? = nil) {
        if let error = error as? LiteMDError {
            present(error)
        } else {
            runAlert(
                title: title ?? String(localized: "The operation could not be completed."),
                message: error.localizedDescription,
                buttons: [String(localized: "OK")],
                details: String(describing: error)
            )
        }
    }
}
