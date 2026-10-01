import LiteMDEditor
import SwiftUI

/// 菜单与快捷键。所有入口都发出与工具栏相同的意图（spec §67、§106）。
struct LiteMDCommands: Commands {
    let model: AppModel

    var body: some Commands {
        // 与命令面板的可用条件一致：没有文档或文件夹时，对应的菜单项置灰。
        let hasDocument = model.activeDocument != nil
        let hasFile = model.activeDocument?.fileReference != nil
        let hasWorkspace = model.workspace.root != nil

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                Task { await model.updates.check(userInitiated: true) }
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Document") { model.newDocument() }
                .keyboardShortcut("n")
            Button("Open…") { model.showOpenPanel() }
                .keyboardShortcut("o")
            Button("Open Folder…") { model.showOpenFolderPanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Open iCloud Drive Folder…") { model.showOpeniCloudFolderPanel() }
            RecentItemsMenu(model: model)
            Divider()
            Group {
                Button("Quick Open…") { model.isQuickOpenPresented = true }
                    .keyboardShortcut("p")
                    .disabled(!hasWorkspace)
                Button("Command Palette…") { model.isCommandPalettePresented = true }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            .disabled(model.isPresentingSheet)
            Divider()
            Button("Import…") { model.importFromOtherFormats() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Transcribe Recording…") { model.transcribeAudioFromPanel() }
            ExportFormatMenu("Export") { model.export($0) }
                .disabled(!hasDocument)
            ExportFormatMenu("Export Folder") { format in
                if let root = model.workspace.rootURL { model.exportFolder(root, as: format) }
            }
            .disabled(!hasWorkspace || model.isPresentingSheet)
            Button("Print…") { model.printActiveDocument() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(!hasDocument)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { model.closeActiveDocument() }
                .keyboardShortcut("w")
            Button("Reopen Closed Tab") { model.reopenClosedDocument() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!model.documents.canReopenClosedDocument)
            Divider()
            Group {
                Button("Save") { model.saveActiveDocument() }
                    .keyboardShortcut("s")
                Button("Save As…") { model.saveActiveDocumentAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            .disabled(!hasDocument)
            Divider()
            Group {
                Button("Rename…") { model.renameActiveDocument() }
                Button("Version History…") { model.showVersionHistory() }
                    .keyboardShortcut("y", modifiers: [.command, .option])
                    .disabled(model.isPresentingSheet)
                Button("Reveal in Finder") {
                    if let url = model.activeDocument?.fileReference?.url {
                        SystemIntegration.revealInFinder(url)
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Move to Trash") { model.trashActiveDocument() }
            }
            .disabled(!hasFile)
            Divider()
            Button("Back Up Folder Now") { model.backup.backUpNow() }
                .keyboardShortcut("b", modifiers: [.command, .control])
                .disabled(!hasWorkspace)
            Button("Restore from Backup…") { model.isRestorePresented = true }
                .disabled(model.isPresentingSheet)
            Button("Browse S3 Documents…") { model.isRemoteDocumentsPresented = true }
                .disabled(model.isPresentingSheet)
            Button("Upload to S3") { model.uploadActiveDocumentToS3() }
                .disabled(!model.activeDocumentIsFromS3)
            Button("Close Folder") { model.closeWorkspace() }
                .disabled(!hasWorkspace)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Insert Image…") { model.insertImageFromPanel() }
                .keyboardShortcut("i", modifiers: [.command, .control])
                .disabled(!hasDocument)
        }

        TextEditingCommands()

        CommandMenu("Format") {
            FormatMenuItems(model: model)
                .disabled(!hasDocument)
        }

        CommandGroup(before: .sidebar) {
            Button("Toggle Preview") { model.toggleEditorMode() }
                .keyboardShortcut("\\")
            Button("Source Mode") { model.setEditorMode(.source) }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button("Live Preview") { model.setEditorMode(.live) }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Button("Split Preview") { model.setEditorMode(.split) }
                .keyboardShortcut("3", modifiers: [.command, .option])
            Button("Toggle Formatting Toolbar") { model.settings.showFormattingToolbar.toggle() }
            Toggle("Focus Mode", isOn: Bindable(model.settings).focusMode)
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Toggle("Typewriter Scrolling", isOn: Bindable(model.settings).typewriterMode)
                .keyboardShortcut("j", modifiers: [.command, .option])
            Divider()
            Button("Show Files") { model.showSidebar(.files) }
                .keyboardShortcut("1", modifiers: [.command, .control])
            Button("Show Outline") { model.showSidebar(.outline) }
                .keyboardShortcut("2", modifiers: [.command, .control])
            Button("Search in Folder") { model.showSidebar(.search) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Replace in Folder") { model.showReplaceInFolder() }
                .keyboardShortcut("f", modifiers: [.command, .option, .shift])
            Divider()
        }

        CommandGroup(after: .windowArrangement) {
            Divider()
            Button("Show Next Tab") { model.selectDocument(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Show Previous Tab") { model.selectDocument(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
        }
    }
}

/// Format 菜单与工具栏共用。
struct FormatMenuItems: View {
    let model: AppModel

    var body: some View {
        Button("Bold") { model.perform(.toggleBold) }
            .keyboardShortcut("b")
        Button("Italic") { model.perform(.toggleItalic) }
            .keyboardShortcut("i")
        Button("Strikethrough") { model.perform(.toggleStrikethrough) }
            .keyboardShortcut("x", modifiers: [.command, .shift])
        Button("Inline Code") { model.perform(.toggleInlineCode) }
            .keyboardShortcut("`", modifiers: [.control])
        Button("Highlight") { model.perform(.toggleHighlight) }
            .keyboardShortcut("h", modifiers: [.command, .shift])
        Divider()
        Menu("Heading") {
            ForEach(1...6, id: \.self) { level in
                Button("Heading \(level)") { model.perform(.setHeading(level: level)) }
                    .keyboardShortcut(KeyEquivalent(Character("\(level)")))
            }
            Divider()
            Button("Paragraph") { model.perform(.setHeading(level: 0)) }
                .keyboardShortcut("0")
        }
        Divider()
        Button("Quote") { model.perform(.toggleQuote) }
            .keyboardShortcut("'", modifiers: [.command, .option])
        Button("Bulleted List") { model.perform(.toggleBulletList) }
            .keyboardShortcut("u", modifiers: [.command, .option])
        Button("Numbered List") { model.perform(.toggleNumberedList) }
            .keyboardShortcut("o", modifiers: [.command, .option])
        Button("Task List") { model.perform(.toggleTaskList) }
            .keyboardShortcut("x", modifiers: [.command, .option])
        Divider()
        Button("Link") { model.perform(.insertLink(destination: nil)) }
            .keyboardShortcut("k")
        Button("Image…") { model.insertImageFromPanel() }
        Button("Code Block") { model.perform(.insertCodeBlock(language: nil)) }
            .keyboardShortcut("c", modifiers: [.command, .option])
        Button("Table") { model.perform(.insertTable(rows: 2, columns: 2)) }
            .keyboardShortcut("t", modifiers: [.command, .control])
        Button("Horizontal Rule") { model.perform(.insertHorizontalRule) }
            .keyboardShortcut("-", modifiers: [.command, .option])
        Divider()
        Button("Indent") { model.perform(.indent) }
            .keyboardShortcut("]")
        Button("Outdent") { model.perform(.outdent) }
            .keyboardShortcut("[")
    }
}

struct RecentItemsMenu: View {
    let model: AppModel

    var body: some View {
        Menu("Open Recent") {
            let workspaces = model.session.recentWorkspaces
            let files = model.session.recentFiles
            ForEach(workspaces, id: \.self) { url in
                Button(url.lastPathComponent) { model.openRecent(url) }
            }
            if !workspaces.isEmpty, !files.isEmpty {
                Divider()
            }
            ForEach(files, id: \.self) { url in
                Button(url.lastPathComponent) { model.openRecent(url) }
            }
            Divider()
            Button("Clear Menu") { model.session.clearRecents() }
                .disabled(workspaces.isEmpty && files.isEmpty)
        }
    }
}
