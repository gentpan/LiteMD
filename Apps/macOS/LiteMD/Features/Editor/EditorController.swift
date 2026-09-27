import AppKit
import LiteMDApplication
import LiteMDConversion
import LiteMDDomain
import LiteMDEditor
import LiteMDMarkdown
import Observation

/// 编辑器 UI 状态（spec §93），不属于 Document 内容。
@MainActor
@Observable
final class EditorSessionState {
    var line = 1
    var column = 1
    var selectedLength = 0
}

/// NSTextView 子类：拦截粘贴与拖放，交给控制器处理图片与文件。
final class MarkdownTextView: NSTextView {
    weak var controller: EditorController?

    override func mouseDown(with event: NSEvent) {
        // ⌘ 点击打开链接或双链。
        if event.modifierFlags.contains(.command), controller?.openLink(at: event) == true { return }
        if controller?.handleLiveClick(event) == true { return }
        super.mouseDown(with: event)
    }

    override var rangeForUserCompletion: NSRange {
        controller?.wikiCompletionRange() ?? super.rangeForUserCompletion
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        guard flag, movement != NSTextMovement.cancel.rawValue, controller?.wikiCompletionRange() != nil else { return }
        // 选中候选后补上 `]]`。
        let string = self.string as NSString
        let location = selectedRange().location
        let following = string.substring(with: NSRange(location: location, length: min(2, string.length - location)))
        if following != "]]" {
            insertText("]]", replacementRange: selectedRange())
        } else {
            setSelectedRange(NSRange(location: location + 2, length: 0))
        }
    }

    override func paste(_ sender: Any?) {
        if controller?.handlePaste(from: .general) == true { return }
        if controller?.pasteRichTextAsMarkdown(from: .general) == true { return }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if controller?.handlePaste(from: .general) == true { return }
        super.pasteAsPlainText(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if controller?.handleDrop(sender) == true { return true }
        return super.performDragOperation(sender)
    }

    private static let imageReturnTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
    ]

    /// 声明可以接收图片，右键菜单才会出现 iPhone 的“拍照 / 扫描文稿 / 添加速绘”（连续互通相机）。
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if isEditable, let returnType, Self.imageReturnTypes.contains(returnType) {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    /// 连续互通相机与“服务”返回的图片同样保存到资源目录并插入 Markdown。
    override func readSelection(from pboard: NSPasteboard) -> Bool {
        if controller?.handlePaste(from: pboard) == true { return true }
        return super.readSelection(from: pboard)
    }
}

/// 每个打开的文档一个控制器，持有自己的 NSTextView、Undo 栈与滚动位置。
///
/// 数据流：
/// - 用户输入 → NSTextStorage → `Document.applyEdit`（TextBuffer）→ `DocumentService.noteTextDidChange`
/// - 编辑命令 → `EditorEngine` → 经 `shouldChangeText` 应用到视图（可撤销）→ 同上
@MainActor
final class EditorController: NSObject, NSTextViewDelegate, NSTextStorageDelegate, DocumentTextEditing {
    let document: Document
    let session = EditorSessionState()
    let scrollView = OverlayScrollView()
    let textView: MarkdownTextView

    /// 可见区域顶部对应的源文件行（带小数，用于平滑同步）。
    var onVisibleLineChange: ((Double) -> Void)?

    private(set) weak var model: AppModel?
    private let undo = UndoManager()
    private let highlighter = MarkdownHighlighter()
    private var styler: SyntaxStyler
    private var tokens: [HighlightToken] = []
    private var needsFullRestyle = true
    private var pendingEditRange: NSRange?
    private var pendingDelta = 0
    private var highlightTask: Task<Void, Never>?
    private var cursorTask: Task<Void, Never>?
    private var visibleLineTask: Task<Void, Never>?
    private var isLoadingText = false
    private var lineStartsCache: (revision: Int, starts: [Int])?
    private var lastInsetWidth: CGFloat = -1
    private var lastInsetHeight: CGFloat = -1
    /// 专注模式下当前未变淡的区间；nil 表示需要重新计算。
    private var focusedRange: NSRange?
    /// 是否加过变淡效果。关闭专注模式时靠它判断要不要清除，不能靠 focusedRange：
    /// 排版设置变化和文字编辑都会把 focusedRange 置空。
    private var hasFocusDimming = false
    /// `[[` 自动补全的候选（异步取得后缓存）。
    private var wikiCandidates: [String] = []
    /// 实时预览：隐藏非当前行的语法标记，标题放大，显示图片、代码块底色等。
    private(set) var isLivePreview = false
    private let liveLayoutDelegate = LiveLayoutDelegate()
    /// 光标所在行（实时预览中这些行显示完整语法）。
    private var activeLineRange = NSRange(location: NSNotFound, length: 0)
    /// 最近一次着色时使用的当前行。
    private var styledActiveLineRange = NSRange(location: NSNotFound, length: 0)
    private var tokensRevision = -1
    /// 上次应用设置时的主题；主题变化后需要让 TextKit 重新解析颜色。
    private var appliedTheme: ColorTheme?
    /// 右键菜单中的“共享”需要在菜单存在期间保留 picker。
    var retainedSharingPicker: NSSharingServicePicker?

    init(document: Document, model: AppModel) {
        self.document = document
        self.model = model
        self.styler = SyntaxStyler(typography: model.settings.editorTypography)
        self.textView = MarkdownTextView(usingTextLayoutManager: true)
        super.init()
        configureViews()
        loadText()
        document.textEditor = self
    }

    private var settings: AppSettings? { model?.settings }

    // MARK: Setup

    private func configureViews() {
        scrollView.installThinScrollers()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Palette.editorBackground
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.postsFrameChangedNotifications = true

        textView.controller = self
        textView.delegate = self
        textView.textStorage?.delegate = self
        textView.textLayoutManager?.delegate = liveLayoutDelegate
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = Palette.editorBackground
        textView.insertionPointColor = Palette.primary
        textView.registerForDraggedTypes([.fileURL])

        NotificationCenter.default.addObserver(self, selector: #selector(visibleRegionDidChange(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(frameDidChange(_:)), name: NSView.frameDidChangeNotification, object: scrollView)

        applyLayoutSettings()
    }

    func applySettings() {
        guard let settings else { return }
        let typography = settings.editorTypography
        // 外观与颜色主题使用动态颜色，重绘即可；只有排版参数变化才需要重新着色（重新着色会让滚动位置跳动）。
        let needsRestyle = typography != styler.typography
        if needsRestyle {
            styler = SyntaxStyler(typography: typography)
        }
        applyLayoutSettings(fontChanged: needsRestyle)
        let theme = ThemeRuntime.shared.theme
        if needsRestyle {
            needsFullRestyle = true
            scheduleHighlight(immediately: true)
        } else if theme != appliedTheme, let layoutManager = textView.textLayoutManager {
            // 颜色是动态颜色，但 TextKit 会缓存解析结果；重新排版即可换成新主题的颜色，字体不变，滚动位置保持。
            let origin = scrollView.contentView.bounds.origin
            layoutManager.invalidateLayout(for: layoutManager.documentRange)
            textView.needsDisplay = true
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else {
            textView.needsDisplay = true
        }
        appliedTheme = theme
    }

    private func applyLayoutSettings(fontChanged: Bool = true) {
        scrollView.backgroundColor = Palette.editorBackground
        textView.backgroundColor = Palette.editorBackground
        textView.insertionPointColor = Palette.primary
        textView.selectedTextAttributes = [.backgroundColor: Palette.selection]
        // 设置 NSTextView.font 会改写全文字体，只在字体变化时设置。
        if fontChanged {
            textView.font = styler.baseFont
        }
        textView.typingAttributes = styler.base
        let wordWrap = settings?.wordWrap ?? true
        if wordWrap {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.frame.size.width = scrollView.contentSize.width
        } else {
            scrollView.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        lastInsetWidth = -1
        updateInsets()
        focusedRange = nil
        updateFocusDimming()
        centerCaretIfNeeded()
    }

    private func updateInsets() {
        let available = scrollView.contentSize.width
        let height = scrollView.contentSize.height
        guard available != lastInsetWidth || height != lastInsetHeight else { return }
        lastInsetWidth = available
        lastInsetHeight = height

        var horizontal = Layout.editorMinimumInset
        if settings?.wordWrap ?? true, let maximum = settings?.lineWidthPoints {
            horizontal = max(Layout.editorMinimumInset, (available - maximum) / 2)
        }
        // 打字机滚动需要上下留白，第一行与最后一行也能滚到中间。
        let vertical = settings?.typewriterMode == true ? max(Space.s6, (height / 2).rounded()) : Space.s6
        let inset = NSSize(width: horizontal.rounded(), height: vertical)
        if textView.textContainerInset != inset {
            textView.textContainerInset = inset
        }
    }

    private func loadText() {
        isLoadingText = true
        textView.textStorage?.setAttributedString(NSAttributedString(string: document.text, attributes: styler.base))
        isLoadingText = false
        textView.typingAttributes = styler.base
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        needsFullRestyle = true
        scheduleHighlight(immediately: true)
    }

    func focus() {
        textView.window?.makeFirstResponder(textView)
    }

    /// 为悬浮工具栏留出空间，使最后几行可以滚动到工具栏上方。
    func setBottomContentInset(_ inset: CGFloat) {
        guard scrollView.contentInsets.bottom != inset else { return }
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: inset, right: 0)
    }

    func tearDown() {
        highlightTask?.cancel()
        cursorTask?.cancel()
        visibleLineTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        textView.delegate = nil
        textView.textStorage?.delegate = nil
        textView.controller = nil
    }

    // MARK: Text storage → TextBuffer

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            storageDidEditCharacters(in: editedRange, delta: delta)
        }
    }

    private func storageDidEditCharacters(in editedRange: NSRange, delta: Int) {
        guard !isLoadingText, let storage = textView.textStorage else { return }
        let oldRange = NSRange(location: editedRange.location, length: editedRange.length - delta)
        let string = storage.string as NSString

        if oldRange.length >= 0, NSMaxRange(oldRange) <= document.buffer.length {
            document.applyEdit(range: oldRange, replacement: string.substring(with: editedRange))
        }
        // 防御：视图与缓冲区长度不一致时整体同步，绝不让两者分叉。
        if document.buffer.length != storage.length {
            document.applyEdit(range: NSRange(location: 0, length: document.buffer.length), replacement: storage.string)
            needsFullRestyle = true
        }

        if var pending = pendingEditRange {
            if editedRange.location <= pending.location {
                pending.location = max(0, pending.location + delta)
            } else if editedRange.location <= NSMaxRange(pending) {
                pending.length = max(0, pending.length + delta)
            }
            pendingEditRange = NSUnionRange(pending, editedRange)
        } else {
            pendingEditRange = editedRange
        }
        pendingDelta += delta
        lineStartsCache = nil
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        focusedRange = nil
        let isComposing = textView.hasMarkedText()
        if !isComposing { triggerWikiCompletionIfNeeded() }
        model?.documents.noteTextDidChange(document, isComposing: isComposing)
        if !isComposing {
            scheduleHighlight()
        }
        scheduleCursorUpdate()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        scheduleCursorUpdate()
        updateFocusDimming()
        syncLiveActiveLines()
        if settings?.typewriterMode == true {
            // 等 NSTextView 完成自身的滚动后再居中。
            Task { @MainActor [weak self] in self?.centerCaretIfNeeded() }
        }
    }

    // MARK: Links

    func openLink(at event: NSEvent) -> Bool {
        let point = textView.convert(event.locationInWindow, from: nil)
        let index = textView.characterIndexForInsertion(at: point)
        let text = document.text
        if let link = MarkdownExtensionScanner.wikiLinks(in: text).first(where: { NSLocationInRange(index, $0.range) }) {
            model?.openWikiLink(target: link.target, anchor: link.anchor, from: document)
            return true
        }
        if let link = MarkdownLinkLocator.link(at: index, in: text) {
            model?.openLinkDestination(link.destination, relativeTo: document)
            return true
        }
        return false
    }

    /// 光标位于 `[[…` 之后（同一行、尚未闭合）时返回待补全的区间。
    func wikiCompletionRange() -> NSRange? {
        let string = textView.string as NSString
        let caret = textView.selectedRange()
        guard caret.length == 0, caret.location <= string.length else { return nil }
        let lineStart = string.lineRange(for: NSRange(location: caret.location, length: 0)).location
        let prefix = string.substring(with: NSRange(location: lineStart, length: caret.location - lineStart))
        guard let open = prefix.range(of: "[[", options: .backwards) else { return nil }
        let partial = prefix[open.upperBound...]
        guard !partial.contains("]"), !partial.contains("["), !partial.contains("|"), !partial.contains("#") else { return nil }
        let length = (String(partial) as NSString).length
        return NSRange(location: caret.location - length, length: length)
    }

    private func triggerWikiCompletionIfNeeded() {
        let string = textView.string as NSString
        let caret = textView.selectedRange().location
        guard caret >= 2, caret <= string.length, string.substring(with: NSRange(location: caret - 2, length: 2)) == "[[",
              let model else { return }
        Task { [weak self] in
            let names = await model.wikiLinkCompletions()
            guard let self, !names.isEmpty, self.wikiCompletionRange() != nil else { return }
            self.wikiCandidates = names
            self.textView.complete(nil)
        }
    }

    func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
        guard wikiCompletionRange() != nil else { return words }
        let partial = (textView.string as NSString).substring(with: charRange).lowercased()
        let matches = wikiCandidates.filter { partial.isEmpty || $0.lowercased().contains(partial) }
        index?.pointee = matches.isEmpty ? -1 : 0
        let sorted = matches.sorted { lhs, rhs in
            let lhsPrefix = lhs.lowercased().hasPrefix(partial)
            let rhsPrefix = rhs.lowercased().hasPrefix(partial)
            return lhsPrefix != rhsPrefix ? lhsPrefix : lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return Array(sorted.prefix(50))
    }

    // MARK: Focus & typewriter

    /// 当前块：光标所在的、以空行分隔的段落。
    func currentBlockRange() -> NSRange {
        let string = textView.string as NSString
        let selection = textView.selectedRange()
        guard string.length > 0 else { return NSRange(location: 0, length: 0) }
        var start = string.lineRange(for: NSRange(location: min(selection.location, string.length), length: 0)).location
        var end = NSMaxRange(string.lineRange(for: NSRange(location: min(NSMaxRange(selection), string.length), length: 0)))
        func isBlank(_ range: NSRange) -> Bool {
            string.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        while start > 0 {
            let previous = string.lineRange(for: NSRange(location: start - 1, length: 0))
            if isBlank(previous) { break }
            start = previous.location
        }
        while end < string.length {
            let next = string.lineRange(for: NSRange(location: end, length: 0))
            if isBlank(next) { break }
            end = NSMaxRange(next)
        }
        return NSRange(location: start, length: end - start)
    }

    /// 通过 TextKit 2 的渲染属性变淡，不修改正文属性，也不进入撤销栈。
    private func updateFocusDimming() {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return }
        let length = textView.textStorage?.length ?? 0
        func textRange(_ range: NSRange) -> NSTextRange? {
            guard let start = contentManager.location(contentManager.documentRange.location, offsetBy: range.location),
                  let end = contentManager.location(start, offsetBy: range.length) else { return nil }
            return NSTextRange(location: start, end: end)
        }

        // 输入法组字期间保持现状，避免变淡效果来回闪。
        guard !textView.hasMarkedText() else { return }
        guard settings?.focusMode == true else {
            if hasFocusDimming {
                layoutManager.removeRenderingAttribute(.foregroundColor, for: contentManager.documentRange)
                hasFocusDimming = false
            }
            focusedRange = nil
            return
        }
        let block = currentBlockRange()
        guard block != focusedRange else { return }
        focusedRange = block
        hasFocusDimming = true
        layoutManager.removeRenderingAttribute(.foregroundColor, for: contentManager.documentRange)
        let dimmed = Palette.textTertiary.withAlphaComponent(0.6)
        if block.location > 0, let before = textRange(NSRange(location: 0, length: block.location)) {
            layoutManager.addRenderingAttribute(.foregroundColor, value: dimmed, for: before)
        }
        if NSMaxRange(block) < length, let after = textRange(NSRange(location: NSMaxRange(block), length: length - NSMaxRange(block))) {
            layoutManager.addRenderingAttribute(.foregroundColor, value: dimmed, for: after)
        }
    }

    private func centerCaretIfNeeded() {
        guard settings?.typewriterMode == true, let window = textView.window else { return }
        let selection = textView.selectedRange()
        let screenRect = textView.firstRect(forCharacterRange: NSRange(location: selection.location, length: 0), actualRange: nil)
        guard screenRect != .zero else { return }
        let windowRect = window.convertFromScreen(screenRect)
        let caret = textView.convert(windowRect, from: nil)
        let visible = scrollView.contentView.bounds
        let targetY = caret.midY - visible.height / 2
        guard abs(targetY - visible.minY) > 1 else { return }
        let maxY = max(0, textView.frame.height - visible.height)
        scrollView.contentView.scroll(to: NSPoint(x: visible.minX, y: min(max(0, targetY), maxY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        undo
    }

    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        guard let model else { return menu }
        return EditorContextMenuBuilder(controller: self, model: model, systemMenu: menu, characterIndex: charIndex).build()
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        // 粘贴或拖入的文本统一为 LF，保证缓冲区里永远只有 `\n`。
        guard let replacementString, replacementString.contains("\r") else { return true }
        let normalized = TextCodec.normalizeLineEndings(replacementString).text
        textView.insertText(normalized, replacementRange: affectedCharRange)
        return false
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            return perform(.insertNewline)
        case #selector(NSResponder.insertTab(_:)):
            return shouldIndentOnTab() ? perform(.indent) : false
        case #selector(NSResponder.insertBacktab(_:)):
            return perform(.outdent)
        default:
            return false
        }
    }

    private func shouldIndentOnTab() -> Bool {
        let selection = textView.selectedRange()
        let string = textView.string as NSString
        if selection.length > 0, string.substring(with: selection).contains("\n") { return true }
        let line = string.substring(with: string.lineRange(for: NSRange(location: selection.location, length: 0)))
        return MarkdownLineSyntax.parseListPrefix(line.trimmingCharacters(in: .newlines)) != nil
    }

    // MARK: Commands

    @discardableResult
    func perform(_ command: EditorCommand) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        let engine = EditorEngine(
            indentUnit: settings?.indentUnit ?? "    ",
            listContinuation: settings?.listContinuation ?? true
        )
        let selection = Selection(range: textView.selectedRange())
        guard let result = engine.perform(command, text: document.text, selection: selection) else { return false }
        apply(result, actionName: Self.actionName(for: command))
        return true
    }

    func apply(_ result: EditResult, actionName: String? = nil) {
        let range = result.edit.range
        guard NSMaxRange(range) <= (textView.textStorage?.length ?? 0),
              textView.shouldChangeText(in: range, replacementString: result.edit.replacement) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: result.edit.replacement, attributes: styler.base))
        textView.didChangeText()
        if let actionName { undo.setActionName(actionName) }
        textView.setSelectedRange(result.selection.range)
        textView.scrollRangeToVisible(result.selection.range)
    }

    /// Reload 等整体替换：走编辑通道，因此可以撤销。
    func replaceEntireText(with text: String) {
        replaceEntireText(with: text, actionName: String(localized: "Reload"))
    }

    func replaceEntireText(with text: String, actionName: String) {
        guard let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let visible = scrollView.contentView.bounds.origin
        let full = NSRange(location: 0, length: storage.length)
        if textView.shouldChangeText(in: full, replacementString: text) {
            storage.replaceCharacters(in: full, with: NSAttributedString(string: text, attributes: styler.base))
            textView.didChangeText()
            undo.setActionName(actionName)
        }
        let length = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        scrollView.contentView.scroll(to: visible)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        needsFullRestyle = true
        scheduleHighlight(immediately: true)
    }

    private static func actionName(for command: EditorCommand) -> String {
        switch command {
        case .toggleBold: String(localized: "Bold")
        case .toggleItalic: String(localized: "Italic")
        case .toggleStrikethrough: String(localized: "Strikethrough")
        case .toggleInlineCode: String(localized: "Inline Code")
        case .toggleHighlight: String(localized: "Highlight")
        case .setHeading: String(localized: "Heading")
        case .toggleQuote: String(localized: "Quote")
        case .toggleBulletList: String(localized: "Bulleted List")
        case .toggleNumberedList: String(localized: "Numbered List")
        case .toggleTaskList: String(localized: "Task List")
        case .toggleTaskCompletion: String(localized: "Toggle Task")
        case .insertLink: String(localized: "Insert Link")
        case .insertImage: String(localized: "Insert Image")
        case .insertCodeBlock: String(localized: "Insert Code Block")
        case .insertTable: String(localized: "Insert Table")
        case .insertHorizontalRule: String(localized: "Insert Horizontal Rule")
        case .indent: String(localized: "Indent")
        case .outdent: String(localized: "Outdent")
        case .insertNewline: String(localized: "Typing")
        }
    }

    // MARK: Navigation

    func reveal(range: NSRange) {
        let length = textView.textStorage?.length ?? 0
        let location = min(range.location, length)
        let clamped = NSRange(location: location, length: min(range.length, length - location))
        scrollToOffset(clamped.location)
        textView.setSelectedRange(clamped)
        textView.showFindIndicator(for: clamped)
        focus()
    }

    /// 把指定偏移所在的行滚动到可见区域顶部附近（Outline 跳转）。
    func scrollToOffset(_ offset: Int) {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let location = contentManager.location(contentManager.documentRange.location, offsetBy: offset) else { return }
        layoutManager.ensureLayout(for: NSTextRange(location: location))
        guard let fragment = layoutManager.textLayoutFragment(for: location) else { return }
        let y = fragment.layoutFragmentFrame.minY + textView.textContainerOrigin.y - Space.s6
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func moveCursor(to offset: Int) {
        let location = min(offset, textView.textStorage?.length ?? 0)
        scrollToOffset(location)
        textView.setSelectedRange(NSRange(location: location, length: 0))
        focus()
    }

    // MARK: Highlighting

    private func scheduleHighlight(immediately: Bool = false) {
        highlightTask?.cancel()
        let length = document.buffer.length
        let delay: Duration = immediately ? .zero : .milliseconds(length > 500_000 ? 150 : 40)

        highlightTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let self else { return }
            let revision = self.document.revision
            let text = self.document.buffer.snapshot()
            self.styledActiveLineRange = self.currentLineRange()
            let highlighter = self.highlighter
            let newTokens = await Task.detached(priority: .userInitiated) {
                highlighter.tokens(in: text)
            }.value
            guard !Task.isCancelled, revision == self.document.revision, !self.textView.hasMarkedText() else { return }
            await self.applyTokens(newTokens)
        }
    }

    private func applyTokens(_ newTokens: [HighlightToken]) async {
        guard let storage = textView.textStorage else { return }
        let length = storage.length
        let oldTokens = tokens
        let editRange = pendingEditRange
        let delta = pendingDelta
        tokens = newTokens
        tokensRevision = document.revision
        pendingEditRange = nil
        pendingDelta = 0
        activeLineRange = currentLineRange()

        if needsFullRestyle {
            needsFullRestyle = false
            await restyleInChunks(length: length)
            return
        }
        guard let dirty = Self.dirtyRange(old: oldTokens, new: newTokens, edit: editRange, delta: delta, length: length) else {
            syncLiveActiveLines()
            return
        }
        let paragraphs = (storage.string as NSString).paragraphRange(for: dirty)
        restyle(paragraphs)
        syncLiveActiveLines()
    }

    /// 大文档首次着色分块进行，每块之间让出主线程，保证输入不卡顿。
    private func restyleInChunks(length: Int) async {
        let chunkSize = 64_000
        let revision = document.revision
        var location = 0
        while location < length {
            let string = (textView.textStorage?.string ?? "") as NSString
            guard string.length == length else {
                needsFullRestyle = true
                return
            }
            let end = min(length, location + chunkSize)
            let range = string.paragraphRange(for: NSRange(location: location, length: end - location))
            restyle(range)
            location = NSMaxRange(range)
            if location < length {
                await Task.yield()
                guard revision == document.revision, !Task.isCancelled else {
                    needsFullRestyle = true
                    scheduleHighlight()
                    return
                }
            }
        }
    }

    private func restyle(_ range: NSRange) {
        guard let storage = textView.textStorage, range.length > 0, NSMaxRange(range) <= storage.length else { return }
        storage.beginEditing()
        storage.setAttributes(styler.base, range: range)
        var index = firstTokenIndex(atOrAfter: range.location)
        let end = NSMaxRange(range)
        let string = storage.string as NSString
        while index < tokens.count {
            let token = tokens[index]
            if token.range.location >= end { break }
            let clipped = NSIntersectionRange(token.range, range)
            if clipped.length > 0 {
                if isLivePreview {
                    applyLiveStyle(token, clipped: clipped, storage: storage, string: string)
                } else {
                    storage.addAttributes(styler.attributes(for: token.kind), range: clipped)
                }
            }
            index += 1
        }
        if isLivePreview {
            applyLineDecorations(in: range, storage: storage, string: string)
        }
        storage.endEditing()
        textView.typingAttributes = styler.base
    }

    // MARK: Live preview

    func setLivePreview(_ enabled: Bool) {
        guard enabled != isLivePreview else { return }
        isLivePreview = enabled
        activeLineRange = currentLineRange()
        needsFullRestyle = true
        scheduleHighlight(immediately: true)
    }

    private func currentLineRange() -> NSRange {
        let string = textView.string as NSString
        let selection = textView.selectedRange()
        guard selection.location <= string.length else { return NSRange(location: NSNotFound, length: 0) }
        return string.lineRange(for: NSRange(location: selection.location, length: min(selection.length, string.length - selection.location)))
    }

    private func isActive(_ range: NSRange) -> Bool {
        guard activeLineRange.location != NSNotFound else { return false }
        return NSIntersectionRange(range, activeLineRange).length > 0
            || NSLocationInRange(range.location, activeLineRange)
            || (range.location == NSMaxRange(activeLineRange) && range.location == (textView.textStorage?.length ?? 0))
    }

    /// 光标换行后，重新着色离开的行与进入的行。只在高亮结果与正文一致时进行，否则等高亮完成。
    private func syncLiveActiveLines() {
        guard isLivePreview, !textView.hasMarkedText() else { return }
        activeLineRange = currentLineRange()
        guard tokensRevision == document.revision, activeLineRange != styledActiveLineRange else { return }
        let previous = styledActiveLineRange
        styledActiveLineRange = activeLineRange
        let length = textView.textStorage?.length ?? 0
        let string = textView.string as NSString
        for range in [previous, activeLineRange] where range.location != NSNotFound && NSMaxRange(range) <= length {
            restyle(string.lineRange(for: range))
        }
    }

    private func applyLiveStyle(_ token: HighlightToken, clipped: NSRange, storage: NSTextStorage, string: NSString) {
        let active = isActive(token.range)
        var attributes = styler.attributes(for: token.kind)
        switch token.kind {
        case .heading1: attributes[.font] = styler.liveHeadingFont(level: 1)
        case .heading2: attributes[.font] = styler.liveHeadingFont(level: 2)
        case .heading3: attributes[.font] = styler.liveHeadingFont(level: 3)
        case .heading4: attributes[.font] = styler.liveHeadingFont(level: 4)
        case .heading5: attributes[.font] = styler.liveHeadingFont(level: 5)
        case .heading6: attributes[.font] = styler.liveHeadingFont(level: 6)
        case .marker, .url, .image, .horizontalRule:
            guard active else {
                var hidden = clipped
                // 行首标记（`#`、`>`）连同后面的一个空格一起隐藏。
                let lineStart = string.lineRange(for: NSRange(location: token.range.location, length: 0)).location
                let prefix = string.substring(with: NSRange(location: lineStart, length: token.range.location - lineStart))
                if token.kind == .marker, prefix.allSatisfy({ $0 == " " || $0 == ">" }),
                   NSMaxRange(hidden) < string.length, string.character(at: NSMaxRange(hidden)) == 0x20 {
                    hidden.length += 1
                }
                storage.addAttributes(styler.hiddenAttributes, range: hidden)
                return
            }
        case .inlineCode:
            attributes[.backgroundColor] = Palette.surfaceMuted
        case .link, .wikiLink:
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        case .taskBox:
            attributes = [.font: styler.codeFont, .foregroundColor: Palette.primary]
        default:
            break
        }
        storage.addAttributes(attributes, range: clipped)
    }

    /// 行级装饰：代码块底色、引用竖线与缩进、分隔线、图片预览。
    private func applyLineDecorations(in range: NSRange, storage: NSTextStorage, string: NSString) {
        var lineStart = range.location
        let end = NSMaxRange(range)
        while lineStart < end {
            let line = string.lineRange(for: NSRange(location: lineStart, length: 0))
            let kinds = tokenKinds(inLine: line)
            if kinds.contains(.codeBlock) || kinds.contains(.codeFence) {
                storage.addAttribute(.liveDecoration, value: LiveDecoration(kind: .codeBlock), range: line)
            } else if kinds.contains(.horizontalRule), !isActive(line) {
                storage.addAttribute(.liveDecoration, value: LiveDecoration(kind: .rule), range: line)
            } else if kinds.contains(.quote) {
                let paragraph = (styler.base[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                paragraph.firstLineHeadIndent = Space.s4
                paragraph.headIndent = Space.s4
                storage.addAttributes([.liveDecoration: LiveDecoration(kind: .quote), .paragraphStyle: paragraph], range: line)
            } else if kinds.contains(.image), let decoration = imageDecoration(forLine: line, string: string) {
                let paragraph = (styler.base[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                paragraph.paragraphSpacing = decoration.imageSize.height + Space.s4
                storage.addAttributes([.liveDecoration: decoration, .paragraphStyle: paragraph], range: line)
            }
            guard NSMaxRange(line) > lineStart else { break }
            lineStart = NSMaxRange(line)
        }
    }

    private func tokenKinds(inLine line: NSRange) -> Set<HighlightKind> {
        var kinds = Set<HighlightKind>()
        var index = firstTokenIndex(atOrAfter: line.location)
        while index < tokens.count, tokens[index].range.location < NSMaxRange(line) {
            kinds.insert(tokens[index].kind)
            index += 1
        }
        return kinds
    }

    private func imageDecoration(forLine line: NSRange, string: NSString) -> LiveDecoration? {
        guard let model else { return nil }
        let text = string.substring(with: line).trimmingCharacters(in: .newlines)
        guard let link = MarkdownLinkLocator.links(inLine: text).first(where: { $0.kind == .image }),
              let url = model.resolveLocalURL(link.destination, relativeTo: document) else { return nil }
        let lineLocation = line.location
        guard let image = LiveImageCache.shared.image(for: url, onLoad: { [weak self] in
            guard let self, self.isLivePreview, lineLocation < (self.textView.textStorage?.length ?? 0) else { return }
            self.restyle((self.textView.string as NSString).lineRange(for: NSRange(location: lineLocation, length: 0)))
        }) else { return nil }
        let padding = textView.textContainer?.lineFragmentPadding ?? 0
        let width = max(Space.s16, textView.bounds.width - textView.textContainerInset.width * 2 - padding * 2)
        let size = LiveImageCache.displaySize(for: image, maximumWidth: width)
        return LiveDecoration(kind: .image, image: image, imageSize: size)
    }

    /// 实时预览中单击 `[ ]` 切换任务状态。
    func handleLiveClick(_ event: NSEvent) -> Bool {
        guard isLivePreview, event.clickCount == 1, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return false }
        let point = textView.convert(event.locationInWindow, from: nil)
        let index = textView.characterIndexForInsertion(at: point)
        let lineStart = (textView.string as NSString).lineRange(for: NSRange(location: min(index, textView.string.utf16.count), length: 0)).location
        var tokenIndex = firstTokenIndex(atOrAfter: lineStart)
        while tokenIndex < tokens.count, tokens[tokenIndex].range.location <= index {
            let token = tokens[tokenIndex]
            if token.kind == .taskBox, NSLocationInRange(index, NSRange(location: token.range.location, length: token.range.length + 1)) {
                textView.setSelectedRange(NSRange(location: token.range.location, length: 0))
                perform(.toggleTaskCompletion)
                return true
            }
            tokenIndex += 1
        }
        return false
    }

    private func firstTokenIndex(atOrAfter location: Int) -> Int {
        var low = 0
        var high = tokens.count
        while low < high {
            let middle = (low + high) / 2
            if tokens[middle].range.location < location {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    /// 通过比较新旧 token 的相同前缀与后缀，只重新着色真正变化的区域。
    static func dirtyRange(old: [HighlightToken], new: [HighlightToken], edit: NSRange?, delta: Int, length: Int) -> NSRange? {
        let limit = min(old.count, new.count)
        var prefix = 0
        while prefix < limit, old[prefix] == new[prefix] {
            if let edit, NSMaxRange(new[prefix].range) > edit.location { break }
            prefix += 1
        }

        var suffix = 0
        while suffix < limit - prefix {
            let oldToken = old[old.count - 1 - suffix]
            let newToken = new[new.count - 1 - suffix]
            let shifted = NSRange(location: oldToken.range.location + delta, length: oldToken.range.length)
            guard oldToken.kind == newToken.kind, shifted == newToken.range else { break }
            if let edit, newToken.range.location < NSMaxRange(edit) { break }
            suffix += 1
        }

        var start = Int.max
        var end = Int.min
        let editStart = edit?.location ?? 0
        for token in old[prefix..<(old.count - suffix)] {
            let location = token.range.location < editStart ? token.range.location : token.range.location + delta
            start = min(start, location)
            end = max(end, location + token.range.length)
        }
        for token in new[prefix..<(new.count - suffix)] {
            start = min(start, token.range.location)
            end = max(end, NSMaxRange(token.range))
        }
        if let edit {
            start = min(start, edit.location)
            end = max(end, NSMaxRange(edit))
        }
        guard start != Int.max else { return nil }
        start = max(0, min(start, length))
        end = max(start, min(end, length))
        return NSRange(location: start, length: end - start)
    }

    // MARK: Cursor & scroll

    private func lineStarts() -> [Int] {
        if let cache = lineStartsCache, cache.revision == document.revision {
            return cache.starts
        }
        var starts = [0]
        var offset = 0
        for unit in (textView.string as NSString as String).utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        lineStartsCache = (document.revision, starts)
        return starts
    }

    private func lineIndex(for offset: Int, in starts: [Int]) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= offset {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    private func scheduleCursorUpdate() {
        cursorTask?.cancel()
        cursorTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let self else { return }
            self.updateCursorInfo()
        }
    }

    private func updateCursorInfo() {
        let selection = textView.selectedRange()
        let starts = lineStarts()
        let index = lineIndex(for: selection.location, in: starts)
        let lineStart = starts[index]
        let string = textView.string as NSString
        let prefixLength = max(0, min(selection.location, string.length) - lineStart)
        let prefix = string.substring(with: NSRange(location: lineStart, length: prefixLength))
        session.line = index + 1
        session.column = prefix.count + 1
        session.selectedLength = selection.length
    }

    @objc private func visibleRegionDidChange(_ notification: Notification) {
        guard onVisibleLineChange != nil, visibleLineTask == nil else { return }
        visibleLineTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard let self else { return }
            self.visibleLineTask = nil
            if let line = self.topVisibleLine() {
                self.onVisibleLineChange?(line)
            }
        }
    }

    @objc private func frameDidChange(_ notification: Notification) {
        updateInsets()
    }

    func topVisibleLine() -> Double? {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return nil }
        let visible = textView.visibleRect
        let origin = textView.textContainerOrigin
        let point = CGPoint(x: Space.s1, y: max(0, visible.minY - origin.y))
        guard let fragment = layoutManager.textLayoutFragment(for: point) else { return nil }
        let offset = contentManager.offset(from: contentManager.documentRange.location, to: fragment.rangeInElement.location)
        let starts = lineStarts()
        let line = Double(lineIndex(for: offset, in: starts) + 1)
        let frame = fragment.layoutFragmentFrame
        guard frame.height > 0 else { return line }
        let fraction = min(1, max(0, (visible.minY - origin.y - frame.minY) / frame.height))
        return line + fraction
    }

    // MARK: Images

    func handlePaste(from pasteboard: NSPasteboard) -> Bool {
        let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !fileURLs.isEmpty, fileURLs.allSatisfy(MarkdownFileType.isImage) {
            importImages(files: fileURLs)
            return true
        }
        let types = pasteboard.types ?? []
        guard !types.contains(.string), let image = Self.imageData(from: pasteboard) else { return false }
        importImage(data: image.data, fileExtension: image.fileExtension)
        return true
    }

    /// 从网页、Word、Google 文档等处复制的富文本粘贴成 Markdown：标题、列表、链接、粗体、表格都保留下来。
    /// “粘贴为纯文本”不经过这里；光标在代码块里、内容来自代码编辑器、原文没有格式时也照原样粘贴。
    func pasteRichTextAsMarkdown(from pasteboard: NSPasteboard) -> Bool {
        guard let html = pasteboard.string(forType: .html), !isCaretInCodeBlock,
              let markdown = PastedHTML.markdown(fromHTML: html, plainText: pasteboard.string(forType: .string)) else { return false }
        let range = textView.selectedRange()
        let caret = range.location + (markdown as NSString).length
        apply(EditResult(edit: TextEdit(range: range, replacement: markdown), selection: Selection(cursor: caret)), actionName: String(localized: "Paste"))
        return true
    }

    /// 光标是否在围栏代码块里。直接扫描光标之前的各行，不依赖异步算出的高亮结果：
    /// 刚打开文档、高亮还没算完时也要判断正确。
    private var isCaretInCodeBlock: Bool {
        let string = textView.string as NSString
        let caret = min(textView.selectedRange().location, string.length)
        let units = Array(string.substring(to: caret).utf16)
        var open: MarkdownFence?
        var lineStart = 0
        for (index, unit) in units.enumerated() where unit == 0x0A {
            let line = MarkdownFence.parse(units, lineStart, index)
            if let fence = open {
                if let line, fence.isClosed(by: line) { open = nil }
            } else if let line {
                open = line
            }
            lineStart = index + 1
        }
        return open != nil
    }

    func handleDrop(_ info: any NSDraggingInfo) -> Bool {
        let pasteboard = info.draggingPasteboard
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }

        if urls.allSatisfy(MarkdownFileType.isImage) {
            let point = textView.convert(info.draggingLocation, from: nil)
            let index = textView.characterIndexForInsertion(at: point)
            textView.setSelectedRange(NSRange(location: index, length: 0))
            importImages(files: urls)
            return true
        }
        // 文档与文件夹：在 LiteMD 中打开，而不是把路径插入正文。
        Task { await model?.open(urls) }
        return true
    }

    func importImages(files: [URL]) {
        guard !files.isEmpty, let model, let documentURL = requireDocumentURL() else { return }
        let location = model.settings.assetLocation
        Task {
            var paths: [String] = []
            for file in files {
                do {
                    paths.append(try await model.assets.importFile(at: file, forDocumentAt: documentURL, location: location).markdownPath)
                } catch {
                    SystemIntegration.present(error)
                }
            }
            insertImages(paths)
        }
    }

    private func importImage(data: Data, fileExtension: String) {
        guard let model, let documentURL = requireDocumentURL() else { return }
        let location = model.settings.assetLocation
        Task {
            do {
                let result = try await model.assets.importImageData(data, fileExtension: fileExtension, forDocumentAt: documentURL, location: location)
                insertImages([result.markdownPath])
            } catch {
                SystemIntegration.present(error)
            }
        }
    }

    private func requireDocumentURL() -> URL? {
        if let url = document.fileReference?.url { return url }
        SystemIntegration.present(LiteMDError(kind: .asset, reason: .requiresSavedDocument, fileName: document.displayName))
        return nil
    }

    /// 图片插入同样经过 EditorCommand（spec §172）。
    private func insertImages(_ paths: [String]) {
        for (index, path) in paths.enumerated() {
            if index > 0 {
                textView.insertText("\n", replacementRange: textView.selectedRange())
            }
            perform(.insertImage(path: path, alt: ""))
        }
    }

    private static func imageData(from pasteboard: NSPasteboard) -> (data: Data, fileExtension: String)? {
        if let png = pasteboard.data(forType: .png) {
            return (png, "png")
        }
        if let jpeg = pasteboard.data(forType: NSPasteboard.PasteboardType("public.jpeg")) {
            return (jpeg, "jpg")
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let representation = NSBitmapImageRep(data: tiff),
           let png = representation.representation(using: .png, properties: [:]) {
            return (png, "png")
        }
        // 其他图片格式（例如 HEIC）统一转为 PNG。
        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let representation = NSBitmapImageRep(data: tiff),
           let png = representation.representation(using: .png, properties: [:]) {
            return (png, "png")
        }
        return nil
    }
}
