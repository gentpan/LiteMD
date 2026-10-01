import LiteMDDomain
import SwiftUI
import UniformTypeIdentifiers

struct MainWindowView: View {
    static let windowID = "main"

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model

        Group {
            if model.showsWelcome {
                WelcomeView()
            } else {
                workspaceLayout
            }
        }
        .frame(minWidth: Layout.windowMinimumWidth, minHeight: Layout.windowMinimumHeight)
        .environment(\.colorTheme, model.settings.activeTheme)
        .environment(\.locale, .interface)
        .tint(Color.themeAccent(model.settings.activeTheme))
        .task {
            model.openMainWindow = { openWindow(id: Self.windowID) }
            model.openSettingsWindow = { openSettings() }
            model.backup.openSettings = { [model] in model.openSettingsTab(.backup) }
            await model.start()
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadDroppedURLs(providers)
            return true
        }
        .sheet(isPresented: $model.isQuickOpenPresented) {
            QuickOpenView()
                .environment(model)
        }
        .sheet(isPresented: $model.isCommandPalettePresented) {
            CommandPaletteView()
                .environment(model)
        }
        .sheet(isPresented: $model.isRestorePresented) {
            RestoreBackupView()
                .environment(model)
        }
        .sheet(isPresented: $model.isRemoteDocumentsPresented) {
            RemoteDocumentsView()
                .environment(model)
        }
        .sheet(item: $model.versionHistoryDocument) { document in
            VersionHistoryView(document: document)
                .environment(model)
        }
        .sheet(item: $model.folderExportRequest) { request in
            FolderExportView(request: request)
                .environment(model)
        }
        .sheet(item: $model.compareRequest) { request in
            CompareView(request: request)
                .environment(model)
        }
        .alert("Rename", isPresented: renamePresented) {
            TextField("Name", text: renameName)
            Button("Rename") {
                if let request = model.renameRequest {
                    model.performRename(request)
                }
                model.renameRequest = nil
            }
            Button("Cancel", role: .cancel) {
                model.renameRequest = nil
            }
        } message: {
            Text("Enter a new name for “\(model.renameRequest?.url.lastPathComponent ?? "")”.")
        }
        .alert("LiteMD closed unexpectedly.", isPresented: recoveryPresented) {
            Button("Recover") { model.recoverDocuments() }
            Button("Discard", role: .destructive) { model.discardRecovery() }
        } message: {
            let count = model.pendingRecovery.count
            if count == 1 {
                Text("Recover 1 unsaved document?")
            } else {
                Text("Recover \(count) unsaved documents?")
            }
        }
    }

    private var workspaceLayout: some View {
        @Bindable var model = model
        return NavigationSplitView(columnVisibility: $model.columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(
                    min: Layout.sidebarMinimumWidth,
                    ideal: Layout.sidebarIdealWidth,
                    max: Layout.sidebarMaximumWidth
                )
        } detail: {
            EditorAreaView()
        }
        // 文件名已显示在标签页上，工具栏不再重复绘制标题（见 LiteMDApp 的 windowToolbarStyle）；
        // 窗口标题仍保留给“窗口”菜单与调度中心。
        .navigationTitle(model.windowTitle)
        // 工具栏本身透明：侧栏与编辑区各自的背景延伸到标题栏，侧栏上下连成一体。
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            EditorToolbar()
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { model.renameRequest != nil },
            set: { if !$0 { model.renameRequest = nil } }
        )
    }

    private var renameName: Binding<String> {
        Binding(
            get: { model.renameRequest?.name ?? "" },
            set: { model.renameRequest?.name = $0 }
        )
    }

    private var recoveryPresented: Binding<Bool> {
        Binding(get: { !model.pendingRecovery.isEmpty }, set: { _ in })
    }

    private func loadDroppedURLs(_ providers: [NSItemProvider]) {
        let model = self.model
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    await model.open([url])
                }
            }
        }
    }
}

struct EditorToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        @Bindable var model = model

        // 标签页占据标题栏中间的弹性区域，格式、图片、模式按钮因此位于最右侧。
        ToolbarItem(id: "tabs", placement: .principal) {
            TitlebarTabStrip()
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                FormatMenuItems(model: model)
            } label: {
                Label {
                    Text("Format")
                } icon: {
                    Image.interfaceSymbol("textformat")
                }
            }
            .help("Format")
            .disabled(model.activeDocument == nil)

            Button {
                model.insertImageFromPanel()
            } label: {
                Label("Insert Image", systemImage: "photo")
            }
            .help("Insert Image")
            .disabled(model.activeDocument == nil)

            Picker("Mode", selection: $model.editorMode) {
                Label("Source", systemImage: "doc.plaintext").tag(EditorMode.source)
                Label("Live Preview", systemImage: "eye").tag(EditorMode.live)
                Label("Split Preview", systemImage: "rectangle.split.2x1").tag(EditorMode.split)
            }
            .pickerStyle(.segmented)
            .help("Editor Mode (⌘\\)")
        }
    }
}
