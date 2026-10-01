import AppKit
import LiteMDApplication
import LiteMDBackup
import SwiftUI

/// S3 文档浏览器：列出桶里所有 Markdown，选一篇下载到本地打开。
struct RemoteDocumentsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: String?
    @State private var bucket = ""

    private struct Node: Identifiable, Hashable {
        let id: String
        let name: String
        let document: RemoteDocument?
        var children: [Node]?
    }

    var body: some View {
        let remote = model.remoteDocuments

        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content(remote)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: Space.s2) {
                Button("Show Download Folder") { showDownloadFolder() }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Download and Open") { selectedDocument.map(open) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedDocument == nil)
            }
            .padding(Space.s4)
        }
        .frame(width: Layout.remoteDocumentsWidth, height: Layout.remoteDocumentsHeight)
        .task {
            bucket = model.settings.backupBrowserBucket
            await remote.refresh()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Space.s4) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text("S3 Documents")
                    .font(.system(size: TextSize.lg, weight: .semibold))
                Text("Download a document to edit it on this Mac. When you are done, upload it to replace the S3 copy, or keep it local.")
                    .font(.system(size: TextSize.xs))
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.s4)
            HStack(spacing: Space.s2) {
                Text("Bucket")
                    .font(.system(size: TextSize.xs))
                    .foregroundStyle(Color.textSecondary)
                TextField("Bucket", text: $bucket, prompt: Text(verbatim: model.settings.backupBucket))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: Layout.remoteBucketFieldWidth)
                    .onSubmit { reload() }
                    .help("Leave empty to use the backup bucket.")
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload")
                .accessibilityLabel("Reload")
                .disabled(model.remoteDocuments.phase == .loading)
            }
        }
        .padding(Space.s4)
    }

    @ViewBuilder
    private func content(_ remote: RemoteDocumentsModel) -> some View {
        if !remote.isConfigured {
            ContentUnavailableView {
                Label("S3 Is Not Set Up", systemImage: "icloud.slash")
            } description: {
                Text("Enter your Amazon S3 or Cloudflare R2 bucket and keys in Backup settings. Browsing uses the same account.")
            } actions: {
                Button("Open Backup Settings…") {
                    dismiss()
                    model.openSettingsTab(.backup)
                }
            }
        } else {
            switch remote.phase {
            case .idle, .loading:
                ProgressView()
            case .failed(let message):
                ContentUnavailableView {
                    Label("Could Not Load Documents", systemImage: "exclamationmark.icloud")
                } description: {
                    Text(verbatim: message)
                } actions: {
                    Button("Try Again") { reload() }
                }
            case .loaded:
                if remote.documents.isEmpty {
                    ContentUnavailableView("No Markdown Documents", systemImage: "doc.text.magnifyingglass", description: Text("There are no .md files in “\(remote.configuration.bucket)”."))
                } else {
                    VStack(spacing: 0) {
                        TextField("Search", text: $query, prompt: Text("Filter by name or folder"))
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: query) { selectFirstMatch() }
                            .onSubmit { selectedDocument.map(open) }
                            .padding(.horizontal, Space.s4)
                            .padding(.vertical, Space.s2)
                        documentList(remote)
                    }
                }
            }
        }
    }

    private func documentList(_ remote: RemoteDocumentsModel) -> some View {
        let nodes = query.isEmpty ? Self.tree(remote.documents) : Self.matches(remote.documents, query: query)
        return List(nodes, children: \.children, selection: $selection) { node in
            row(node, remote: remote)
                .tag(node.id)
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { _ in
        } primaryAction: { ids in
            if let id = ids.first, let document = remote.documents.first(where: { $0.key == id }) {
                open(document)
            }
        }
    }

    private func row(_ node: Node, remote: RemoteDocumentsModel) -> some View {
        HStack(spacing: Space.s3) {
            Image(systemName: node.document == nil ? "folder" : "doc.text")
                .foregroundStyle(Color.textSecondary)
                .frame(width: IconSize.inline)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: node.name)
                    .font(.system(size: TextSize.sm))
                    .foregroundStyle(Color.textPrimary)
                if !query.isEmpty, let document = node.document, document.key.contains("/") {
                    Text(verbatim: (document.key as NSString).deletingLastPathComponent)
                        .font(.system(size: TextSize.xs))
                        .foregroundStyle(Color.textTertiary)
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: Space.s3)
            if let document = node.document {
                if let state = remote.states[document.key] {
                    StateBadge(state: state)
                }
                Text(verbatim: ByteCountFormatter.string(fromByteCount: document.size, countStyle: .file))
                    .frame(minWidth: Space.s16, alignment: .trailing)
                Text(verbatim: document.lastModified?.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: .interface)) ?? "")
                    .frame(minWidth: Layout.remoteDateColumnWidth, alignment: .trailing)
            }
        }
        .font(.system(size: TextSize.xs).monospacedDigit())
        .foregroundStyle(Color.textSecondary)
        .padding(.vertical, Space.s1)
    }

    private var selectedDocument: RemoteDocument? {
        selection.flatMap { id in model.remoteDocuments.documents.first { $0.key == id } }
    }

    private func open(_ document: RemoteDocument) {
        dismiss()
        Task { await model.remoteDocuments.open(document) }
    }

    /// 筛选时选中第一个匹配项：输入几个字按回车就能打开。
    private func selectFirstMatch() {
        guard !query.isEmpty else { return }
        let matches = Self.matches(model.remoteDocuments.documents, query: query)
        if !matches.contains(where: { $0.id == selection }) {
            selection = matches.first?.id
        }
    }

    private func reload() {
        let trimmed = bucket.trimmingCharacters(in: .whitespaces)
        model.settings.backupBrowserBucket = trimmed
        selection = nil
        Task { await model.remoteDocuments.refresh() }
    }

    private func showDownloadFolder() {
        let folder = RemoteDocumentsModel.downloadsRoot(bucket: model.remoteDocuments.configuration.bucket)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    // MARK: Tree

    /// 按 `/` 拆成目录树：每层文件夹在前、文件在后，各自按名称排序。
    private static func tree(_ documents: [RemoteDocument]) -> [Node] {
        final class Folder {
            var folders: [String: Folder] = [:]
            var files: [RemoteDocument] = []
        }
        let root = Folder()
        for document in documents {
            let parts = document.key.split(separator: "/").map(String.init)
            var folder = root
            for part in parts.dropLast() {
                if folder.folders[part] == nil { folder.folders[part] = Folder() }
                folder = folder.folders[part]!
            }
            folder.files.append(document)
        }
        func nodes(_ folder: Folder, path: String) -> [Node] {
            let folders = folder.folders.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
                let id = path + name + "/"
                return Node(id: id, name: name, document: nil, children: nodes(folder.folders[name]!, path: id))
            }
            let files = folder.files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map {
                Node(id: $0.key, name: $0.name, document: $0, children: nil)
            }
            return folders + files
        }
        return nodes(root, path: "")
    }

    private static func matches(_ documents: [RemoteDocument], query: String) -> [Node] {
        documents
            .filter { $0.key.localizedCaseInsensitiveContains(query) }
            .map { Node(id: $0.key, name: $0.name, document: $0, children: nil) }
    }
}

private struct StateBadge: View {
    let state: RemoteDocumentState

    var body: some View {
        switch state {
        case .notDownloaded:
            EmptyView()
        case .synced:
            Label("Downloaded", systemImage: "checkmark.circle")
                .foregroundStyle(Color.textTertiary)
        case .localChanges:
            Label("Not Uploaded", systemImage: "arrow.up.circle")
                .foregroundStyle(Color.statusWarning)
        case .remoteChanges:
            Label("Updated in S3", systemImage: "arrow.down.circle")
                .foregroundStyle(Color.brand)
        case .bothChanged:
            Label("Changed on Both Sides", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Color.statusWarning)
        }
    }
}

/// 状态栏里的 S3 标记：显示是否有未上传的修改，菜单里上传或取消关联。
struct RemoteDocumentStatusMenu: View {
    @Environment(AppModel.self) private var model
    let document: Document
    let link: RemoteDocumentLink

    var body: some View {
        let remote = model.remoteDocuments
        let url = document.fileReference?.url
        let isPending = remote.hasPendingUpload(url) || document.isDirty

        Menu {
            Button("Upload to S3") { Task { await remote.upload(document) } }
                .disabled(remote.isBusy(url))
            Divider()
            Button("Keep Local Only") {
                if let url { remote.unlink(url) }
            }
        } label: {
            if remote.isBusy(url) {
                Text("Uploading…")
            } else if isPending {
                Label("Not Uploaded", systemImage: "icloud.and.arrow.up")
            } else {
                Label("S3", systemImage: "checkmark.icloud")
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // 无边框菜单的标题跟随强调色，这里按状态指定，与状态栏其余文字一致。
        .tint(isPending ? Color.statusWarning : Color.textSecondary)
        .help(Text(verbatim: "s3://\(link.bucket)/\(link.key)"))
    }
}
