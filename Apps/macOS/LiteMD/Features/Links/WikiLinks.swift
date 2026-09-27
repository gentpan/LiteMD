import AppKit
import LiteMDApplication
import LiteMDDomain
import Observation
import SwiftUI

/// 当前文档的反向链接。切换文档或文件变化时后台重新计算。
@MainActor
@Observable
final class BacklinksModel {
    private(set) var backlinks: [Backlink] = []
    private(set) var isLoading = false
    private(set) var documentURL: URL?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored weak var model: AppModel?

    func refresh(for url: URL?) {
        task?.cancel()
        let isSameDocument = url == documentURL
        documentURL = url
        guard let url, let model, let root = model.workspace.rootURL else {
            backlinks = []
            isLoading = false
            return
        }
        // 同一个文档因为文件变化（包括自己的自动保存）重新计算时，保留旧结果、不显示加载状态，
        // 否则每保存一次反向链接区域就闪一下。
        if !isSameDocument {
            isLoading = true
        }
        task = Task { [weak self] in
            // 连续切换文档时只计算最后一个。
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            let files = await model.workspace.allMarkdownFiles()
            let result = await model.backlinkIndex.backlinks(to: url, root: root, files: files)
            guard !Task.isCancelled, self.documentURL == url else { return }
            self.backlinks = result
            self.isLoading = false
        }
    }
}

@MainActor
extension AppModel {
    /// 打开 `[[目标#标题]]`。目标不存在时询问是否新建。
    func openWikiLink(target: String, anchor: String?, from document: Document?) {
        Task {
            let files = await workspace.allMarkdownFiles()
            let sourceURL = document?.fileReference?.url
            if let url = WikiLinkResolver.resolve(target, from: sourceURL, root: workspace.rootURL, candidates: files) {
                guard let opened = await openDocument(url) else { return }
                if let anchor { revealAnchor(anchor, in: opened) }
                return
            }
            if target.isEmpty, let document, let anchor {
                revealAnchor(anchor, in: document)
                return
            }
            await offerToCreateNote(named: target, near: sourceURL)
        }
    }

    private func revealAnchor(_ anchor: String, in document: Document) {
        // 解析结果可能稍后才到，稍等一次。
        Task {
            for _ in 0..<10 {
                if let headings = document.parseResult?.headings {
                    let wanted = anchor.lowercased()
                    if let heading = headings.first(where: { $0.title.lowercased() == wanted || $0.anchor == wanted }) {
                        editor(for: document).moveCursor(to: heading.offset)
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func offerToCreateNote(named target: String, near sourceURL: URL?) async {
        guard let directory = workspace.rootURL ?? sourceURL?.deletingLastPathComponent() else {
            SystemIntegration.runAlert(
                title: String(localized: "“\(target)” was not found."),
                message: String(localized: "Open a folder to link notes by name."),
                buttons: [String(localized: "OK")],
                style: .informational
            )
            return
        }
        // `[[notes/Idea]]` 建在 notes 子文件夹里，这样链接才能解析到它；`.` 与 `..` 丢弃，不会建到文件夹外面。
        let components = target.split(separator: "/")
            .map { WikiLinkResolver.fileName(for: String($0)) }
            .filter { $0 != "." && $0 != ".." }
        guard let name = components.last else { return }
        let folder = components.dropLast().reduce(directory) { $0.appendingPathComponent($1) }
        let relativeName = (components.dropLast() + [name + ".md"]).joined(separator: "/")

        let choice = SystemIntegration.runAlert(
            title: String(localized: "“\(target)” does not exist yet."),
            message: String(localized: "Create a new note named “\(relativeName)” in “\(directory.lastPathComponent)”?"),
            buttons: [String(localized: "Create Note"), String(localized: "Cancel")],
            style: .informational
        )
        guard choice == 0 else { return }

        let url = folder.appendingPathComponent(name).appendingPathExtension("md")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await fileSystem.createFile(at: url, contents: Data("# \(name)\n\n".utf8))
            await workspace.refreshDirectory(directory)
            await workspace.refreshDirectory(folder)
            workspace.invalidateMarkdownFileCache()
            await openDocument(url)
        } catch let error as LiteMDError {
            // 这是文件夹里的操作：错误标题应是“无法创建”，而不是“无法打开”。
            SystemIntegration.present(error.with(kind: .workspace))
        } catch {
            SystemIntegration.present(error)
        }
    }

    /// 双链自动补全的全部候选：Workspace 中的笔记名（重名时带目录）。
    /// 按输入筛选、排序由编辑器负责；这里不能截断，否则按字母排在后面的笔记永远补全不出来。
    func wikiLinkCompletions() async -> [String] {
        guard workspace.rootURL != nil else { return [] }
        let files = await workspace.allMarkdownFiles()
        var counts: [String: Int] = [:]
        for file in files {
            counts[file.deletingPathExtension().lastPathComponent.lowercased(), default: 0] += 1
        }
        let names = files.map { file -> String in
            let name = file.deletingPathExtension().lastPathComponent
            guard counts[name.lowercased(), default: 0] > 1 else { return name }
            return relativePath(for: file.deletingPathExtension())
        }
        return Array(Set(names))
    }
}

/// 大纲面板底部的反向链接列表。
struct BacklinksSection: View {
    @Environment(AppModel.self) private var model
    @State private var isExpanded = true

    var body: some View {
        let backlinks = model.backlinks

        VStack(alignment: .leading, spacing: 0) {
            Divider()
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: Space.s2) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: TextSize.xs, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text("Backlinks")
                        .font(.system(size: TextSize.xs, weight: .semibold))
                    Spacer()
                    if backlinks.isLoading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text(verbatim: "\(backlinks.backlinks.count)")
                            .font(.system(size: TextSize.xs).monospacedDigit())
                    }
                }
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, Space.s4)
                .frame(height: Layout.statusBarHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                if model.workspace.root == nil {
                    placeholder("Open a folder to see which notes link here.")
                } else if backlinks.backlinks.isEmpty, !backlinks.isLoading {
                    placeholder("No other notes link to this document.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Space.s1) {
                            ForEach(backlinks.backlinks) { link in
                                BacklinkRow(link: link)
                            }
                        }
                        .padding(.horizontal, Space.s2)
                        .padding(.bottom, Space.s2)
                    }
                    .frame(maxHeight: Layout.backlinksMaximumHeight)
                }
            }
        }
    }

    private func placeholder(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: TextSize.xs))
            .foregroundStyle(Color.textTertiary)
            .padding(.horizontal, Space.s4)
            .padding(.bottom, Space.s3)
    }
}

private struct BacklinkRow: View {
    @Environment(AppModel.self) private var model
    let link: Backlink
    @State private var isHovering = false

    var body: some View {
        Button {
            model.openSearchResult(link.sourceURL, match: SearchMatch(line: link.line, column: 1, range: link.range, snippet: link.snippet, snippetMatchRange: NSRange(location: 0, length: 0)))
        } label: {
            VStack(alignment: .leading, spacing: Space.s1) {
                HStack(spacing: Space.s1) {
                    Image(systemName: link.kind == .wikiLink ? "link" : "doc.text")
                        .font(.system(size: TextSize.xs))
                    Text(verbatim: link.sourceURL.deletingPathExtension().lastPathComponent)
                        .font(.system(size: TextSize.xs, weight: .semibold))
                    Spacer()
                    Text(verbatim: "\(link.line)")
                        .font(.system(size: TextSize.xs).monospacedDigit())
                        .foregroundStyle(Color.textTertiary)
                }
                .foregroundStyle(Color.textPrimary)
                Text(verbatim: link.snippet)
                    .font(.system(size: TextSize.xs))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
            }
            .padding(Space.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.small)
                    .fill(isHovering ? Color.borderSubtle : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(model.relativePath(for: link.sourceURL))
    }
}
