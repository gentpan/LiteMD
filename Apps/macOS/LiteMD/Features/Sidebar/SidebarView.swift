import LiteMDApplication
import LiteMDDomain
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            SidebarTabBar()
                .padding(.horizontal, Space.s3)
                .padding(.top, Space.s1)
                .padding(.bottom, Space.s2)

            Group {
                switch model.sidebarTab {
                case .files:
                    FileTreeView()
                case .outline:
                    OutlineListView()
                case .search:
                    SearchPanelView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            SidebarFooter()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, model.settings.activeTheme.sidebarIsDark ? .dark : .light)
        .background(Color.sidebarBackground.ignoresSafeArea())
        .modifier(SeamlessScrollEdges())
    }
}

/// 侧栏顶部切换器：撑满宽度，图标 + 文字，选中项白底加一级阴影。
private struct SidebarTabBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.s1 / 2) {
            ForEach(SidebarTab.allCases) { tab in
                SidebarTabButton(tab: tab, isSelected: model.sidebarTab == tab) {
                    model.sidebarTab = tab
                }
            }
        }
        .padding(Space.s1 / 2)
        .background(
            RoundedRectangle(cornerRadius: Radius.medium)
                .fill(Color.borderSubtle)
        )
    }
}

private struct SidebarTabButton: View {
    let tab: SidebarTab
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s1) {
                Image(systemName: tab.symbol)
                    .font(.system(size: TextSize.xs, weight: .medium))
                Text(tab.title)
                    .font(.system(size: TextSize.xs, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected || isHovering ? Color.textPrimary : Color.textSecondary)
            .frame(maxWidth: .infinity, minHeight: Layout.sidebarTabHeight)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: Radius.small)
                        .fill(Color.editorBackground)
                        .shadow(color: Elevation.level1Color, radius: Elevation.level1Radius, x: 0, y: Elevation.level1Offset)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovering = $0 }
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 侧栏底部栏：新建文件 / 文件夹、设置。与编辑区状态栏等高。
private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s1) {
                if let root = model.workspace.root {
                    SidebarIconButton(symbol: "doc.badge.plus", help: "New File") {
                        model.createFile(in: root.url)
                    }
                    SidebarIconButton(symbol: "folder.badge.plus", help: "New Folder") {
                        model.createFolder(in: root.url)
                    }
                } else {
                    SidebarIconButton(symbol: "folder", help: "Open Folder…") {
                        model.showOpenFolderPanel()
                    }
                    SidebarIconButton(symbol: "doc.badge.plus", help: "New Document") {
                        model.newDocument()
                    }
                }
                Spacer()
                if model.workspace.root != nil {
                    BackupStatusButton()
                }
                AppearanceToggleButton()
                SettingsLink {
                    SidebarIconLabel(symbol: "gearshape")
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, Space.s2)
            .frame(height: Layout.statusBarHeight)
        }
    }
}

/// macOS 26 起滚动视图在顶部、底部加了渐隐的边缘效果，会让侧栏看起来分成上中下三段；侧栏关闭它。
private struct SeamlessScrollEdges: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .all)
        } else {
            content
        }
    }
}

/// 浅色 / 深色一键切换。图标表示点击后切换到的外观；右键可恢复“跟随系统”。
private struct AppearanceToggleButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // 侧栏可能与主题明暗不同（深色侧栏），按实际使用的主题槽位判断。
        let isDark = model.settings.usesDarkThemeSlot
        Button {
            model.settings.theme = isDark ? .light : .dark
        } label: {
            SidebarIconLabel(symbol: isDark ? "sun.max" : "moon")
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(isDark ? "Switch to Light Mode" : "Switch to Dark Mode")
        .accessibilityLabel(isDark ? "Switch to Light Mode" : "Switch to Dark Mode")
        .contextMenu {
            Picker("Appearance", selection: Bindable(model.settings).theme) {
                Text("Follow System").tag(AppTheme.system)
                Text("Light").tag(AppTheme.light)
                Text("Dark").tag(AppTheme.dark)
            }
            .pickerStyle(.inline)
        }
    }
}

/// iCloud 状态：未下载显示云朵，下载中显示进度圈，其余不显示。
private struct CloudStatusIcon: View {
    let status: CloudStatus
    let isDownloading: Bool

    var body: some View {
        if isDownloading || status == .downloading(fraction: nil) {
            ProgressView()
                .controlSize(.mini)
        } else if status == .notDownloaded {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: TextSize.xs))
                .foregroundStyle(Color.textTertiary)
                .help("Not downloaded from iCloud yet")
        }
    }
}

struct SidebarIconButton: View {
    let symbol: String
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SidebarIconLabel(symbol: symbol)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct SidebarIconLabel: View {
    let symbol: String
    @State private var isHovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: IconSize.inline, weight: .regular))
            .foregroundStyle(isHovering ? Color.textPrimary : Color.textSecondary)
            .frame(width: Space.s6 + Space.s1, height: Space.s6 + Space.s1)
            .background(
                RoundedRectangle(cornerRadius: Radius.small)
                    .fill(isHovering ? Color.borderSubtle : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

// MARK: - Files

/// 图标与颜色面板是否在指定文件夹上显示。
@MainActor
private func pickerPresented(for url: URL, model: AppModel) -> Binding<Bool> {
    Binding(
        get: { model.folderAppearancePickerURL?.standardizedFileURL == url.standardizedFileURL },
        set: { if !$0, model.folderAppearancePickerURL?.standardizedFileURL == url.standardizedFileURL { model.folderAppearancePickerURL = nil } }
    )
}

struct FileTreeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let root = model.workspace.root {
            VStack(spacing: 0) {
                WorkspaceHeader(root: root)
                List(selection: selection) {
                    ForEach(root.children ?? []) { node in
                        FileTreeRow(node: node)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .contextMenu {
                    WorkspaceContextMenu(directory: root.url)
                }
            }
        } else {
            NoWorkspaceView()
        }
    }

    /// 选中项与当前文档同步；点击文件即打开。
    private var selection: Binding<URL?> {
        Binding(
            get: { model.activeDocument?.fileReference?.url },
            set: { url in
                guard let url, let node = model.workspace.node(for: url) else { return }
                if node.isDirectory {
                    model.workspace.setExpanded(node, !node.isExpanded)
                } else if MarkdownFileType.isDocument(url) {
                    Task { await model.openDocument(url) }
                } else {
                    // 单击就会触发：文件夹里的脚本或应用不能一点就运行。
                    SystemIntegration.openLocalFile(url)
                }
            }
        )
    }
}

/// 工作区标题行：文件夹名称 + 操作菜单。
private struct WorkspaceHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorTheme) private var colorTheme
    let root: WorkspaceNode

    var body: some View {
        let appearance = model.folderAppearance.appearance(for: root.url)
        HStack(spacing: Space.s2) {
            Image(systemName: appearance.symbol.map(\.systemName) ?? "folder")
                .font(.system(size: TextSize.xs, weight: .semibold))
                .foregroundStyle(appearance.color?.color ?? Color.textSecondary)
                .popover(isPresented: pickerPresented(for: root.url, model: model), arrowEdge: .bottom) {
                    FolderAppearancePicker(url: root.url)
                        .environment(model)
                        .environment(\.colorTheme, colorTheme)
                }
            Text(verbatim: root.name)
                .font(.system(size: TextSize.xs, weight: .semibold))
                .foregroundStyle(appearance.tintsName ? (appearance.color?.color ?? Color.textSecondary) : Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Space.s1)
            Menu {
                WorkspaceContextMenu(directory: root.url)
                Divider()
                Button("Icon and Color…") { model.folderAppearancePickerURL = root.url }
                Button("Reveal in Finder") { SystemIntegration.revealInFinder(root.url) }
                Button("Close Folder") { model.closeWorkspace() }
            } label: {
                SidebarIconLabel(symbol: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Folder Actions")
            .accessibilityLabel("Folder Actions")
        }
        .padding(.leading, Space.s4)
        .padding(.trailing, Space.s2)
        .frame(height: Layout.statusBarHeight)
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls where model.workspace.contains(url) {
                model.move(url, into: root.url)
            }
            return true
        }
    }
}

private struct FileTreeRow: View {
    @Environment(\.colorTheme) private var colorTheme
    @Environment(AppModel.self) private var model
    let node: WorkspaceNode

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: expanded) {
                if let children = node.children {
                    ForEach(children) { child in
                        FileTreeRow(node: child)
                    }
                }
            } label: {
                label
            }
            .tag(node.url)
        } else {
            label
                .tag(node.url)
        }
    }

    private var expanded: Binding<Bool> {
        Binding(
            get: { node.isExpanded },
            set: { model.workspace.setExpanded(node, $0) }
        )
    }

    private var label: some View {
        let appearance = node.isDirectory ? model.folderAppearance.appearance(for: node.url) : FolderAppearance()
        return Label {
            HStack(spacing: Space.s1) {
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(appearance.tintsName ? (appearance.color?.color ?? Color.textPrimary) : Color.textPrimary)
                if let document = openDocument, document.isDirty {
                    Circle()
                        .fill(Color.textSecondary)
                        .frame(width: Layout.dirtyIndicator, height: Layout.dirtyIndicator)
                }
                CloudStatusIcon(status: node.cloudStatus, isDownloading: model.isDownloadingFromCloud(node.url))
            }
        } icon: {
            if node.isDirectory {
                FolderIcon(appearance: appearance, isExpanded: node.isExpanded)
            } else {
                Image(systemName: symbol)
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .popover(isPresented: pickerPresented(for: node.url, model: model), arrowEdge: .trailing) {
            FolderAppearancePicker(url: node.url)
                .environment(model)
                .environment(\.colorTheme, colorTheme)
        }
        .draggable(node.url)
        .dropDestination(for: URL.self) { urls, _ in
            guard node.isDirectory else { return false }
            for url in urls where model.workspace.contains(url) {
                model.move(url, into: node.url)
            }
            return true
        }
        .contextMenu {
            if node.isDirectory {
                WorkspaceContextMenu(directory: node.url)
                Divider()
                Button("Icon and Color…") { model.folderAppearancePickerURL = node.url }
                Divider()
            } else if MarkdownFileType.isDocument(node.url) {
                Button("Open") { Task { await model.openDocument(node.url) } }
                Divider()
            }
            Button("Rename…") { model.requestRename(node.url) }
            Button("Duplicate") { model.duplicate(node.url) }
            if MarkdownFileType.isDocument(node.url) {
                ExportFormatMenu("Export") { model.export(node.url, as: $0) }
            }
            Divider()
            Button("Reveal in Finder") { SystemIntegration.revealInFinder(node.url) }
            Button("Copy Path") { SystemIntegration.copyToPasteboard(node.url.path) }
            Divider()
            Button("Move to Trash", role: .destructive) { model.moveToTrash(node.url) }
        }
    }

    private var openDocument: Document? {
        model.documents.documents.first { $0.fileReference?.url == node.url }
    }

    private var symbol: String {
        if node.isDirectory { return node.isExpanded ? "folder.fill" : "folder" }
        if MarkdownFileType.isImage(node.url) { return "photo" }
        return "doc.text"
    }
}

private struct WorkspaceContextMenu: View {
    @Environment(AppModel.self) private var model
    let directory: URL

    var body: some View {
        Button("New File") { model.createFile(in: directory) }
        Button("New Folder") { model.createFolder(in: directory) }
        Button("Refresh") { Task { await model.workspace.refreshAll() } }
        Divider()
        ExportFormatMenu("Export Folder") { model.exportFolder(directory, as: $0) }
    }
}

private struct NoWorkspaceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if !model.documents.documents.isEmpty {
                List(selection: activeBinding) {
                    Section("Open Documents") {
                        ForEach(model.documents.documents) { document in
                            Label(document.displayName, systemImage: "doc.text")
                                .lineLimit(1)
                                .tag(document.id)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            } else {
                Spacer()
            }

            VStack(spacing: Space.s2) {
                Text("No Folder Open")
                    .font(.system(size: TextSize.sm, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
                Button("Open Folder…") { model.showOpenFolderPanel() }
                    .controlSize(.regular)
            }
            .padding(Space.s4)

            if model.documents.documents.isEmpty {
                Spacer()
            }
        }
    }

    private var activeBinding: Binding<DocumentID?> {
        Binding(
            get: { model.documents.activeDocumentID },
            set: { model.documents.activeDocumentID = $0 }
        )
    }
}

// MARK: - Outline

struct OutlineListView: View {
    @Environment(\.colorTheme) private var colorTheme
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            headingList
                .frame(maxHeight: .infinity)
            BacklinksSection()
        }
        .task(id: model.activeDocument?.fileReference?.url) {
            model.backlinks.refresh(for: model.activeDocument?.fileReference?.url)
        }
    }

    @ViewBuilder
    private var headingList: some View {
        if let document = model.activeDocument, let headings = document.parseResult?.headings, !headings.isEmpty {
            let currentLine = model.editor(for: document).session.line
            let current = headings.last { $0.line <= currentLine }?.id
            List(headings) { heading in
                Button {
                    model.revealHeading(heading)
                } label: {
                    (heading.title.isEmpty ? Text("Untitled Heading") : Text(verbatim: heading.title))
                        .font(.system(size: TextSize.sm, weight: heading.level <= 2 ? .semibold : .regular))
                        .foregroundStyle(heading.id == current ? Color.themeAccent(colorTheme) : Color.textPrimary)
                        .lineLimit(1)
                        .padding(.leading, CGFloat(heading.level - 1) * Space.s3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        } else {
            ContentUnavailableView(
                "No Headings",
                systemImage: "list.bullet.indent",
                description: Text("Headings in the current document appear here.")
            )
        }
    }
}

// MARK: - Search

private extension View {
    /// 侧栏搜索与替换输入框共用的外框。
    func fieldBox() -> some View {
        padding(.horizontal, Space.s2)
            .padding(.vertical, Space.s1)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.small)
                    .stroke(Color.borderSubtle, lineWidth: 1)
            )
    }
}

struct SearchPanelView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        @Bindable var search = model.search

        VStack(spacing: 0) {
            VStack(spacing: Space.s2) {
                HStack(spacing: Space.s1) {
                    Button {
                        search.showsReplace.toggle()
                    } label: {
                        Image(systemName: search.showsReplace ? "chevron.down" : "chevron.right")
                            .font(.system(size: TextSize.xs, weight: .semibold))
                            .foregroundStyle(Color.textTertiary)
                            .frame(width: Space.s4)
                    }
                    .buttonStyle(.plain)
                    .help(search.showsReplace ? "Hide Replace" : "Show Replace")
                    .accessibilityLabel(search.showsReplace ? "Hide Replace" : "Show Replace")

                    searchField(search)
                }
                if search.showsReplace {
                    HStack(spacing: Space.s1) {
                        Color.clear.frame(width: Space.s4, height: 1)
                        replaceField(search)
                    }
                }
                if search.showsReplace, let summary = search.replaceSummary {
                    Text(summary.occurrences == 0 ? "Nothing to replace." : "Replaced \(summary.occurrences) occurrences in \(summary.files) files.")
                        .font(.system(size: TextSize.xs))
                        .foregroundStyle(Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, Space.s4 + Space.s1)
                }
            }
            .padding(Space.s3)

            Divider()

            content(search)
        }
        .onAppear { isFieldFocused = true }
    }

    private func searchField(_ search: SearchModel) -> some View {
        @Bindable var search = search
        return HStack(spacing: Space.s2) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.textTertiary)
            TextField("Search in folder", text: $search.query)
                .textFieldStyle(.plain)
                .focused($isFieldFocused)
                .onSubmit { search.refresh() }
            Toggle(isOn: $search.isCaseSensitive) {
                Text(verbatim: "Aa")
                    .font(.system(size: TextSize.xs, weight: .semibold))
            }
            .accessibilityLabel("Match Case")
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help("Match Case")
        }
        .fieldBox()
    }

    private func replaceField(_ search: SearchModel) -> some View {
        @Bindable var search = search
        return HStack(spacing: Space.s2) {
            Image(systemName: "arrow.2.squarepath")
                .foregroundStyle(Color.textTertiary)
            TextField("Replace with", text: $search.replacement)
                .textFieldStyle(.plain)
                .onSubmit { search.replaceAll() }
            if search.isReplacing {
                ProgressView().controlSize(.mini)
            } else {
                Button("Replace All") { search.replaceAll() }
                    .buttonStyle(.borderless)
                    .font(.system(size: TextSize.xs, weight: .semibold))
                    .disabled(search.query.isEmpty)
                    .help("Replace every match in the folder")
            }
        }
        .fieldBox()
    }

    @ViewBuilder
    private func content(_ search: SearchModel) -> some View {
        if search.query.isEmpty {
            ContentUnavailableView(
                "Search",
                systemImage: "magnifyingglass",
                description: model.workspace.root == nil ? Text("Searches open documents.") : Text("Searches all Markdown files in the folder.")
            )
        } else if search.isSearching && search.results.isEmpty {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if search.results.isEmpty {
            ContentUnavailableView.search(text: search.query)
        } else {
            List {
                ForEach(search.results) { result in
                    Section {
                        ForEach(Array(result.matches.enumerated()), id: \.offset) { _, match in
                            Button {
                                model.openSearchResult(result.url, match: match)
                            } label: {
                                SearchMatchRow(match: match)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text(model.relativePath(for: result.url))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()
            Text("\(search.totalMatches) results in \(search.results.count) files")
                .font(.system(size: TextSize.xs))
                .foregroundStyle(Color.textSecondary)
                .padding(Space.s2)
        }
    }

}

private struct SearchMatchRow: View {
    @Environment(\.colorTheme) private var colorTheme
    let match: SearchMatch

    var body: some View {
        let snippet = match.snippet as NSString
        let range = match.snippetMatchRange
        let safe = NSMaxRange(range) <= snippet.length
        let before = safe ? snippet.substring(to: range.location) : match.snippet
        let hit = safe ? snippet.substring(with: range) : ""
        let after = safe ? snippet.substring(from: NSMaxRange(range)) : ""

        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Text("\(match.line)")
                .font(.system(size: TextSize.xs).monospacedDigit())
                .foregroundStyle(Color.textTertiary)
            Text("\(before)\(Text(hit).bold().foregroundStyle(Color.themeAccent(colorTheme)))\(after)")
                .font(.system(size: TextSize.sm))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
