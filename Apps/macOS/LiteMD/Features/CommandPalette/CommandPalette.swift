import LiteMDDomain
import LiteMDEditor
import SwiftUI

/// 命令面板中的一项。标题已本地化，搜索时同时匹配英文关键词，中文界面输入英文也能找到命令。
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let category: String
    let symbol: String
    var shortcut: String?
    var keywords: String = ""
    var isEnabled = true
    let action: @MainActor () -> Void
}

@MainActor
extension AppModel {
    /// 命令面板的全部命令。菜单、工具栏与命令面板调用同一组意图。
    var paletteCommands: [PaletteCommand] {
        let hasDocument = activeDocument != nil
        let hasFile = activeDocument?.fileReference != nil
        let hasWorkspace = workspace.root != nil
        let file = String(localized: "File")
        let edit = String(localized: "Format")
        let view = String(localized: "View")
        let tools = String(localized: "Tools")

        var commands: [PaletteCommand] = [
            PaletteCommand(id: "new", title: String(localized: "New Document"), category: file, symbol: "square.and.pencil", shortcut: "⌘N", keywords: "new document create") { self.newDocument() },
            PaletteCommand(id: "open", title: String(localized: "Open…"), category: file, symbol: "doc", shortcut: "⌘O", keywords: "open file") { self.showOpenPanel() },
            PaletteCommand(id: "openFolder", title: String(localized: "Open Folder…"), category: file, symbol: "folder", shortcut: "⇧⌘O", keywords: "open folder workspace") { self.showOpenFolderPanel() },
            PaletteCommand(id: "openiCloud", title: String(localized: "Open iCloud Drive Folder…"), category: file, symbol: "icloud", keywords: "icloud drive folder open sync") { self.showOpeniCloudFolderPanel() },
            PaletteCommand(id: "moveToiCloud", title: String(localized: "Move Folder to iCloud Drive…"), category: file, symbol: "icloud.and.arrow.up", keywords: "move icloud drive sync folder", isEnabled: hasWorkspace && !workspaceIsInCloud && CloudLocation.iCloudDriveURL != nil) { self.moveWorkspaceToiCloudDrive() },
            PaletteCommand(id: "quickOpen", title: String(localized: "Quick Open…"), category: file, symbol: "magnifyingglass", shortcut: "⌘P", keywords: "quick open go to file", isEnabled: hasWorkspace) { self.isQuickOpenPresented = true },
            PaletteCommand(id: "save", title: String(localized: "Save"), category: file, symbol: "square.and.arrow.down", shortcut: "⌘S", keywords: "save", isEnabled: hasDocument) { self.saveActiveDocument() },
            PaletteCommand(id: "saveAs", title: String(localized: "Save As…"), category: file, symbol: "square.and.arrow.down.on.square", shortcut: "⇧⌘S", keywords: "save as", isEnabled: hasDocument) { self.saveActiveDocumentAs() },
            PaletteCommand(id: "close", title: String(localized: "Close Tab"), category: file, symbol: "xmark", shortcut: "⌘W", keywords: "close tab", isEnabled: hasDocument) { self.closeActiveDocument() },
            PaletteCommand(id: "reopen", title: String(localized: "Reopen Closed Tab"), category: file, symbol: "arrow.uturn.backward", shortcut: "⇧⌘T", keywords: "reopen closed tab", isEnabled: documents.canReopenClosedDocument) { self.reopenClosedDocument() },
            PaletteCommand(id: "rename", title: String(localized: "Rename…"), category: file, symbol: "pencil", keywords: "rename", isEnabled: hasFile) { self.renameActiveDocument() },
            PaletteCommand(id: "reveal", title: String(localized: "Reveal in Finder"), category: file, symbol: "folder", shortcut: "⇧⌘R", keywords: "reveal finder show", isEnabled: hasFile) {
                if let url = self.activeDocument?.fileReference?.url { SystemIntegration.revealInFinder(url) }
            },
            PaletteCommand(id: "history", title: String(localized: "Version History…"), category: file, symbol: "clock.arrow.circlepath", shortcut: "⌥⌘Y", keywords: "version history restore revert snapshot", isEnabled: hasFile) { self.showVersionHistory() },
            PaletteCommand(id: "trash", title: String(localized: "Move to Trash"), category: file, symbol: "trash", keywords: "delete trash remove", isEnabled: hasFile) { self.trashActiveDocument() },
            PaletteCommand(id: "import", title: String(localized: "Import…"), category: file, symbol: "square.and.arrow.down", shortcut: "⇧⌘I", keywords: "import convert word pdf docx") { self.importFromOtherFormats() },
            PaletteCommand(id: "transcribe", title: String(localized: "Transcribe Recording…"), category: file, symbol: "waveform", keywords: "transcribe audio recording speech voice", isEnabled: true) { self.transcribeAudioFromPanel() },
            PaletteCommand(id: "dictation", title: String(localized: "Start Dictation"), category: edit, symbol: "mic", keywords: "dictation voice speech input", isEnabled: hasDocument) { self.startDictation() },
            PaletteCommand(id: "print", title: String(localized: "Print…"), category: file, symbol: "printer", shortcut: "⌥⌘P", keywords: "print", isEnabled: hasDocument) { self.printActiveDocument() },
            PaletteCommand(id: "folderAppearance", title: String(localized: "Folder Icon and Color…"), category: file, symbol: "paintpalette", keywords: "folder icon color highlight", isEnabled: hasWorkspace) {
                self.showSidebar(.files)
                self.folderAppearancePickerURL = self.workspace.rootURL
            },
            PaletteCommand(id: "closeFolder", title: String(localized: "Close Folder"), category: file, symbol: "folder.badge.minus", keywords: "close folder workspace", isEnabled: hasWorkspace) { self.closeWorkspace() },
        ]

        for format in ExportFormat.allCases {
            commands.append(PaletteCommand(
                id: "export.\(format.rawValue)",
                title: String(localized: "Export as \(format.displayName)"),
                category: file,
                symbol: "square.and.arrow.up",
                keywords: "export \(format.rawValue)",
                isEnabled: hasDocument
            ) { self.export(format) })
        }

        let formatting: [(String, String, String, String?, EditorCommand)] = [
            ("bold", String(localized: "Bold"), "bold", "⌘B", .toggleBold),
            ("italic", String(localized: "Italic"), "italic", "⌘I", .toggleItalic),
            ("strikethrough", String(localized: "Strikethrough"), "strikethrough", "⇧⌘X", .toggleStrikethrough),
            ("inlineCode", String(localized: "Inline Code"), "chevron.left.forwardslash.chevron.right", "⌃`", .toggleInlineCode),
            ("highlight", String(localized: "Highlight"), "highlighter", "⇧⌘H", .toggleHighlight),
            ("quote", String(localized: "Quote"), "text.quote", "⌥⌘'", .toggleQuote),
            ("bulletList", String(localized: "Bulleted List"), "list.bullet", "⌥⌘U", .toggleBulletList),
            ("numberedList", String(localized: "Numbered List"), "list.number", "⌥⌘O", .toggleNumberedList),
            ("taskList", String(localized: "Task List"), "checklist", "⌥⌘X", .toggleTaskList),
            ("link", String(localized: "Link"), "link", "⌘K", .insertLink(destination: nil)),
            ("codeBlock", String(localized: "Code Block"), "curlybraces", "⌥⌘C", .insertCodeBlock(language: nil)),
            ("table", String(localized: "Table"), "tablecells", "⌃⌘T", .insertTable(rows: 2, columns: 2)),
            ("rule", String(localized: "Horizontal Rule"), "minus", "⌥⌘-", .insertHorizontalRule),
        ]
        for (id, title, symbol, shortcut, command) in formatting {
            commands.append(PaletteCommand(id: "format.\(id)", title: title, category: edit, symbol: symbol, shortcut: shortcut, keywords: "format \(id)", isEnabled: hasDocument) {
                self.perform(command)
            })
        }
        for level in 1...6 {
            commands.append(PaletteCommand(id: "format.heading\(level)", title: String(localized: "Heading \(level)"), category: edit, symbol: "textformat.size", shortcut: "⌘\(level)", keywords: "heading h\(level) title", isEnabled: hasDocument) {
                self.perform(.setHeading(level: level))
            })
        }
        commands.append(PaletteCommand(id: "format.image", title: String(localized: "Insert Image…"), category: edit, symbol: "photo", shortcut: "⌃⌘I", keywords: "insert image picture", isEnabled: hasDocument) { self.insertImageFromPanel() })

        commands += [
            PaletteCommand(id: "view.togglePreview", title: String(localized: "Toggle Preview"), category: view, symbol: "rectangle.split.2x1", shortcut: "⌘\\", keywords: "toggle preview split source", isEnabled: hasDocument) { self.toggleEditorMode() },
            PaletteCommand(id: "view.source", title: String(localized: "Source Mode"), category: view, symbol: "doc.plaintext", shortcut: "⌥⌘1", keywords: "source mode plain", isEnabled: hasDocument) { self.setEditorMode(.source) },
            PaletteCommand(id: "view.live", title: String(localized: "Live Preview"), category: view, symbol: "eye", shortcut: "⌥⌘2", keywords: "live preview wysiwyg", isEnabled: hasDocument) { self.setEditorMode(.live) },
            PaletteCommand(id: "view.split", title: String(localized: "Split Preview"), category: view, symbol: "rectangle.split.2x1", shortcut: "⌥⌘3", keywords: "split preview side by side", isEnabled: hasDocument) { self.setEditorMode(.split) },
            PaletteCommand(id: "view.toolbar", title: String(localized: "Toggle Formatting Toolbar"), category: view, symbol: "slider.horizontal.below.rectangle", keywords: "toolbar formatting") { self.settings.showFormattingToolbar.toggle() },
            PaletteCommand(id: "view.focus", title: settings.focusMode ? String(localized: "Turn Off Focus Mode") : String(localized: "Turn On Focus Mode"), category: view, symbol: "scope", shortcut: "⇧⌘E", keywords: "focus mode dim distraction") { self.settings.focusMode.toggle() },
            PaletteCommand(id: "view.typewriter", title: settings.typewriterMode ? String(localized: "Turn Off Typewriter Scrolling") : String(localized: "Turn On Typewriter Scrolling"), category: view, symbol: "character.cursor.ibeam", shortcut: "⌥⌘J", keywords: "typewriter scrolling center caret") { self.settings.typewriterMode.toggle() },
            PaletteCommand(id: "view.files", title: String(localized: "Show Files"), category: view, symbol: "folder", shortcut: "⌃⌘1", keywords: "show files sidebar") { self.showSidebar(.files) },
            PaletteCommand(id: "view.outline", title: String(localized: "Show Outline"), category: view, symbol: "list.bullet.indent", shortcut: "⌃⌘2", keywords: "show outline headings toc") { self.showSidebar(.outline) },
            PaletteCommand(id: "view.search", title: String(localized: "Search in Folder"), category: view, symbol: "magnifyingglass", shortcut: "⇧⌘F", keywords: "search find folder", isEnabled: hasWorkspace) { self.showSidebar(.search) },
            PaletteCommand(id: "view.replace", title: String(localized: "Replace in Folder"), category: view, symbol: "arrow.2.squarepath", shortcut: "⌥⇧⌘F", keywords: "replace find folder all rename term", isEnabled: hasWorkspace) { self.showReplaceInFolder() },
            PaletteCommand(id: "view.nextTab", title: String(localized: "Show Next Tab"), category: view, symbol: "arrow.right", shortcut: "⇧⌘]", keywords: "show next tab") { self.selectDocument(offset: 1) },
            PaletteCommand(id: "view.previousTab", title: String(localized: "Show Previous Tab"), category: view, symbol: "arrow.left", shortcut: "⇧⌘[", keywords: "show previous tab") { self.selectDocument(offset: -1) },
        ]

        for theme in ColorTheme.allCases {
            commands.append(PaletteCommand(
                id: "theme.\(theme.rawValue)",
                title: String(localized: "Theme: \(String(localized: String.LocalizationValue(theme.displayName)))"),
                category: view,
                symbol: "paintpalette",
                keywords: "theme color \(theme.rawValue)"
            ) { self.settings.useThemeForCurrentAppearance(theme) })
        }
        let appearances: [(AppTheme, String)] = [
            (.system, String(localized: "Appearance: System")),
            (.light, String(localized: "Appearance: Light")),
            (.dark, String(localized: "Appearance: Dark")),
        ]
        for (theme, title) in appearances {
            commands.append(PaletteCommand(id: "appearance.\(theme.rawValue)", title: title, category: view, symbol: "circle.lefthalf.filled", keywords: "appearance dark light mode \(theme.rawValue)") {
                self.settings.theme = theme
            })
        }

        commands += [
            PaletteCommand(id: "backup.now", title: String(localized: "Back Up Folder Now"), category: tools, symbol: "icloud.and.arrow.up", shortcut: "⌃⌘B", keywords: "backup s3 upload", isEnabled: hasWorkspace) { self.backup.backUpNow() },
            PaletteCommand(id: "backup.restore", title: String(localized: "Restore from Backup…"), category: tools, symbol: "icloud.and.arrow.down", keywords: "restore backup s3 download") { self.isRestorePresented = true },
            PaletteCommand(id: "updates", title: String(localized: "Check for Updates…"), category: tools, symbol: "arrow.down.circle", keywords: "update upgrade version") { Task { await self.updates.check(userInitiated: true) } },
            PaletteCommand(id: "settings", title: String(localized: "Settings…"), category: tools, symbol: "gearshape", shortcut: "⌘,", keywords: "settings preferences") { self.openSettingsTab(.general) },
            PaletteCommand(id: "settings.backup", title: String(localized: "Backup Settings…"), category: tools, symbol: "externaldrive.badge.icloud", keywords: "backup settings s3") { self.openSettingsTab(.backup) },
        ]
        return commands
    }

    func openSettingsTab(_ tab: SettingsTab) {
        settingsTab = tab
        openSettingsWindow?()
    }
}

struct CommandPaletteView: View {
    @Environment(\.colorTheme) private var colorTheme
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var isFocused: Bool

    var body: some View {
        let matches = CommandPaletteRanking.rank(model.paletteCommands, query: query)

        VStack(spacing: 0) {
            TextField("Type a command", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: TextSize.lg))
                .padding(Space.s4)
                .focused($isFocused)
                .onSubmit { run(matches) }
                .onKeyPress(.downArrow) {
                    selectedIndex = min(selectedIndex + 1, max(0, matches.count - 1))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    selectedIndex = max(selectedIndex - 1, 0)
                    return .handled
                }
                .onKeyPress(.escape) {
                    dismiss()
                    return .handled
                }

            Divider()

            if matches.isEmpty {
                ContentUnavailableView("No Matching Commands", systemImage: "command")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(Array(matches.enumerated()), id: \.element.id) { index, command in
                        HStack(spacing: Space.s3) {
                            Image(systemName: command.symbol)
                                .font(.system(size: IconSize.inline))
                                .foregroundStyle(command.isEnabled ? Color.textSecondary : Color.textTertiary)
                                .frame(width: Space.s6)
                            Text(verbatim: command.title)
                                .font(.system(size: TextSize.sm))
                                .foregroundStyle(command.isEnabled ? Color.textPrimary : Color.textTertiary)
                            Spacer()
                            Text(verbatim: command.category)
                                .font(.system(size: TextSize.xs))
                                .foregroundStyle(Color.textTertiary)
                            if let shortcut = command.shortcut {
                                Text(verbatim: shortcut)
                                    .font(.system(size: TextSize.xs).monospacedDigit())
                                    .foregroundStyle(Color.textSecondary)
                                    .frame(minWidth: Space.s12, alignment: .trailing)
                            }
                        }
                        .lineLimit(1)
                        .padding(.vertical, Space.s1)
                        .contentShape(Rectangle())
                        .listRowBackground(index == selectedIndex ? Color.themeSelection(colorTheme) : Color.clear)
                        .id(index)
                        .onTapGesture {
                            selectedIndex = index
                            run(matches)
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: selectedIndex) { _, index in
                        proxy.scrollTo(index)
                    }
                }
            }
        }
        .frame(width: Layout.quickOpenWidth, height: Layout.quickOpenHeight)
        .onChange(of: query) { selectedIndex = 0 }
        .onAppear { isFocused = true }
    }

    private func run(_ matches: [PaletteCommand]) {
        guard matches.indices.contains(selectedIndex) else { return }
        let command = matches[selectedIndex]
        guard command.isEnabled else { return }
        dismiss()
        // 等面板关闭、焦点回到编辑器后再执行，格式命令才能作用于正文。
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            command.action()
        }
    }
}

enum CommandPaletteRanking {
    /// 同时匹配本地化标题、分类与英文关键词；多个词分别匹配。可用命令排在不可用命令之前。
    static func rank(_ commands: [PaletteCommand], query: String) -> [PaletteCommand] {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map { Array($0) }
        guard !tokens.isEmpty else {
            return commands.filter(\.isEnabled) + commands.filter { !$0.isEnabled }
        }
        var scored: [(command: PaletteCommand, score: Int)] = []
        for command in commands {
            let fields = [command.title, command.keywords, command.category].map { $0.lowercased() }
            var total = 0
            var matchesAll = true
            for token in tokens {
                guard let best = fields.compactMap({ FuzzyMatcher.score(needle: token, in: $0) }).max() else {
                    matchesAll = false
                    break
                }
                total += best
            }
            if matchesAll {
                scored.append((command, total + (command.isEnabled ? 1000 : 0)))
            }
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.command.title.localizedStandardCompare($1.command.title) == .orderedAscending }
            .map(\.command)
    }
}
