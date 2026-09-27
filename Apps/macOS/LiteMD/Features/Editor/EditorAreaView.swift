import AppKit
import LiteMDApplication
import LiteMDDomain
import SwiftUI

struct EditorAreaView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let document = model.activeDocument {
                DocumentEditorView(document: document)
            } else {
                EmptyEditorView()
            }
        }
        // 编辑区背景延伸到透明的标题栏下方，标题栏与正文同色。
        .background(Color.editorBackground.ignoresSafeArea())
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            model.detailColumnWidth = width
        }
    }
}

private struct DocumentEditorView: View {
    @Environment(AppModel.self) private var model
    let document: Document

    var body: some View {
        let editor = model.editor(for: document)

        VStack(spacing: 0) {
            if document.conflict.isConflict {
                ConflictBanner(document: document)
                Divider()
            }

            // 两种模式共用同一个分栏结构，只增删预览，编辑区视图保持同一身份，
            // 切换模式时不会重建编辑器（否则会闪空、卡顿）。
            EditorSplitView(showsTrailing: model.editorMode == .split) {
                editorPane(editor)
            } trailing: {
                PreviewPane(
                    controller: model.preview,
                    documentID: document.id,
                    html: document.parseResult?.html ?? "",
                    baseDirectory: model.previewBaseDirectory(for: document)
                )
            }

            Divider()
            StatusBarView(document: document, session: editor.session)
        }
    }

    private func editorPane(_ editor: EditorController) -> some View {
        let showsToolbar = model.settings.showFormattingToolbar
        return EditorContainerView(controller: editor, bottomInset: showsToolbar ? FormattingToolbar.reservedHeight : 0, isLivePreview: model.editorMode == .live)
            .overlay(alignment: .bottom) {
                if showsToolbar {
                    FormattingToolbar()
                }
            }
    }
}

/// 承载当前文档的 NSScrollView。切换标签页时只替换子视图，保留每个文档自己的 Undo 与滚动位置。
struct EditorContainerView: NSViewRepresentable {
    let controller: EditorController
    var bottomInset: CGFloat = 0
    var isLivePreview = false

    func makeNSView(context: Context) -> EditorHostView {
        EditorHostView()
    }

    func updateNSView(_ view: EditorHostView, context: Context) {
        view.host(controller)
        controller.setBottomContentInset(bottomInset)
        controller.setLivePreview(isLivePreview)
    }
}

final class EditorHostView: NSView {
    private weak var hosted: EditorController?

    /// 只在切换到另一个文档时接管编辑器视图。
    /// 同一个控制器的视图若已被别的容器接管（视图重建期间新旧容器并存），绝不抢回，否则会出现内容闪空。
    func host(_ controller: EditorController) {
        if hosted === controller {
            if controller.scrollView.superview == nil { attach(controller) }
            return
        }
        hosted = controller
        attach(controller)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 容器重新出现在窗口中，而编辑器视图此时不在任何窗口里：重新挂上。
        guard window != nil, let hosted, hosted.scrollView.window == nil else { return }
        attach(hosted)
    }

    private func attach(_ controller: EditorController) {
        let scrollView = controller.scrollView
        subviews.filter { $0 !== scrollView }.forEach { $0.removeFromSuperview() }
        scrollView.removeFromSuperview()
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)

        Task { @MainActor [weak self, weak controller] in
            guard let self, let controller else { return }
            // 只在焦点原本就在编辑器（或没有焦点）时切换过去，绝不抢走搜索框、重命名框等输入焦点，
            // 否则用户以为在别处输入的按键会落进正文。
            let responder = self.window?.firstResponder
            if responder == nil || responder === self.window || responder is MarkdownTextView {
                controller.focus()
            }
            if let line = controller.topVisibleLine() {
                controller.onVisibleLineChange?(line)
            }
        }
    }
}

private struct EmptyEditorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: Space.s4) {
            Image(systemName: "doc.text")
                .font(.system(size: TextSize.xxl))
                .foregroundStyle(Color.textTertiary)
            Text("No Document Open")
                .font(.system(size: TextSize.lg, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            HStack(spacing: Space.s2) {
                Button("New Document") { model.newDocument() }
                Button("Quick Open…") { model.isQuickOpenPresented = true }
                    .disabled(model.workspace.root == nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Tabs

/// 标题栏中的标签页。与红绿灯、工具栏按钮位于同一行。
struct TitlebarTabStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // 工具栏的中间项默认居中；给它“详情栏宽度减去右侧按钮区”的宽度，标签页即从左侧开始排列。
        // 侧栏收起时，红绿灯与侧栏按钮也位于详情栏的标题栏中，需要一并扣除。
        let leading = model.columnVisibility == .detailOnly ? Layout.titlebarLeadingReserve : 0
        let width = max(Layout.tabMinimumWidth, model.detailColumnWidth - Layout.titlebarTrailingReserve - leading)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s1) {
                ForEach(model.documents.documents) { document in
                    TabItemView(document: document, isActive: document.id == model.documents.activeDocumentID)
                }
            }
        }
        .frame(width: width, height: Layout.titlebarTabHeight, alignment: .leading)
    }
}

private struct TabItemView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorTheme) private var colorTheme
    let document: Document
    let isActive: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Space.s2) {
            Image(systemName: document.conflict.isConflict ? "exclamationmark.triangle.fill" : "doc.text")
                .font(.system(size: TextSize.xs))
                .foregroundStyle(document.conflict.isConflict ? Color.statusWarning : Color.textSecondary)

            Text(verbatim: document.displayName)
                .font(.system(size: TextSize.sm, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.textPrimary : Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            ZStack {
                if document.isDirty && !isHovering {
                    Circle()
                        .fill(Color.textSecondary)
                        .frame(width: Layout.dirtyIndicator, height: Layout.dirtyIndicator)
                } else if isHovering || isActive {
                    Button {
                        Task { await model.close(document) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: TextSize.xs, weight: .semibold))
                            .foregroundStyle(Color.textSecondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Close Tab")
                }
            }
            .frame(width: Layout.closeButton, height: Layout.closeButton)
        }
        .padding(.horizontal, Space.s3)
        .frame(minWidth: Layout.tabMinimumWidth, maxWidth: Layout.tabMaximumWidth, minHeight: Layout.titlebarTabHeight)
        .background(
            RoundedRectangle(cornerRadius: Radius.medium)
                .fill(isActive ? Color.editorBackground : (isHovering ? Color.surfaceMuted : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.medium)
                .stroke(isActive ? Color.borderSubtle : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Radius.medium))
        .onTapGesture {
            model.documents.activeDocumentID = document.id
        }
        .onHover { isHovering = $0 }
        .help(document.fileReference?.url.path ?? document.displayName)
        .draggable(document.id.rawValue.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let uuid = UUID(uuidString: raw),
                  let target = model.documents.documents.firstIndex(where: { $0.id == document.id }) else { return false }
            model.documents.moveDocument(DocumentID(uuid), toIndex: target)
            return true
        }
        .contextMenu {
            Button("Close") { Task { await model.close(document) } }
            Button("Close Others") { model.closeOtherDocuments(except: document) }
            Button("Close Tabs to the Right") { model.closeDocumentsToTheRight(of: document) }
            if let url = document.fileReference?.url {
                Divider()
                Button("Rename…") { model.requestRename(url) }
                Button("Version History…") {
                    model.documents.activeDocumentID = document.id
                    model.showVersionHistory()
                }
                ExportFormatMenu("Export") { model.export(url, as: $0) }
                Button("Reveal in Finder") { SystemIntegration.revealInFinder(url) }
                Button("Copy Path") { SystemIntegration.copyToPasteboard(url.path) }
            }
        }
    }
}

// MARK: - Status bar

struct StatusBarView: View {
    @Environment(AppModel.self) private var model
    let document: Document
    let session: EditorSessionState

    var body: some View {
        HStack(spacing: Space.s4) {
            if let statistics = document.parseResult?.statistics {
                Text("\(statistics.words.formatted()) Words")
                Text("\(statistics.characters.formatted()) Characters")
                Text("\(statistics.lines.formatted()) Lines")
                if statistics.readingMinutes > 0 {
                    Text("\(statistics.readingMinutes) min read")
                }
            }
            Text("Ln \(session.line), Col \(session.column)")
            if session.selectedLength > 0 {
                Text("\(session.selectedLength) selected")
            }

            Spacer()

            if case .available(let item) = model.updates.phase {
                Button {
                    model.updates.promptToInstall(item)
                } label: {
                    Label("Update to \(item.version)", systemImage: "arrow.down.circle")
                        .foregroundStyle(Color.brand)
                }
                .buttonStyle(.borderless)
                .help("A new version of LiteMD is available")
            }

            SaveStateLabel(document: document)
            Text(document.fileReference?.encoding.displayName ?? "UTF-8")
            Text(document.fileReference?.lineEnding.displayName ?? "LF")
            Text("Markdown")
        }
        .font(.system(size: TextSize.xs).monospacedDigit())
        .foregroundStyle(Color.textSecondary)
        .lineLimit(1)
        .padding(.horizontal, Space.s3)
        .frame(height: Layout.statusBarHeight)
        .background(Color.surfaceMuted)
    }
}

private struct SaveStateLabel: View {
    let document: Document

    var body: some View {
        switch document.saveState {
        case .clean:
            if document.isUntitled {
                Text("Not Saved")
            } else {
                Label("Saved", systemImage: "checkmark")
                    .foregroundStyle(Color.statusSuccess)
            }
        case .dirty, .scheduled:
            Text(document.isUntitled ? "Not Saved" : "Edited")
        case .saving:
            Text("Saving…")
        case .failed(let error):
            Button {
                SystemIntegration.present(error)
            } label: {
                Label("Save Failed", systemImage: "exclamationmark.circle")
                    .foregroundStyle(Color.statusError)
            }
            .buttonStyle(.borderless)
        }
    }
}

// MARK: - Conflict

private struct ConflictBanner: View {
    @Environment(AppModel.self) private var model
    let document: Document

    var body: some View {
        HStack(spacing: Space.s3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: IconSize.standalone))
                .foregroundStyle(Color.statusWarning)

            VStack(alignment: .leading, spacing: Space.s1) {
                Text(title)
                    .font(.system(size: TextSize.sm, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text(message)
                    .font(.system(size: TextSize.xs))
                    .foregroundStyle(Color.textSecondary)
            }

            Spacer()

            if document.conflict == .externalDeleted {
                Button("Save As…") { Task { await model.saveAs(document) } }
                Button("Save Again") { model.keepLocalVersion(document) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Compare") { model.compare(document) }
                Button("Reload") { model.reloadFromDisk(document) }
                Button("Keep Mine") { model.keepLocalVersion(document) }
            }
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s2)
        .background(Color.warningSurface)
    }

    private var title: String {
        document.conflict == .externalDeleted
            ? String(localized: "“\(document.displayName)” was deleted or moved outside LiteMD.")
            : String(localized: "“\(document.displayName)” was changed outside LiteMD.")
    }

    private var message: String {
        document.conflict == .externalDeleted
            ? String(localized: "Your version is kept here. Save it again to recreate the file.")
            : String(localized: "Autosave is paused. Choose which version to keep — nothing is overwritten until you decide.")
    }
}
