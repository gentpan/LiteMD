import AppKit
import LiteMDApplication
import LiteMDDomain
import SwiftUI

// MARK: - Welcome

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: Space.s8) {
            VStack(spacing: Space.s2) {
                Text(verbatim: "LiteMD")
                    .font(BrandFont.font(size: TextSize.xxl))
                    .foregroundStyle(Color.textPrimary)
                Text("A fast, local-first Markdown editor. Your files stay yours.")
                    .font(.system(size: TextSize.base))
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: Space.s1) {
                WelcomeAction(title: "New Document", symbol: "square.and.pencil", shortcut: "⌘N") {
                    model.newDocument()
                }
                WelcomeAction(title: "Open File…", symbol: "doc", shortcut: "⌘O") {
                    model.showOpenPanel()
                }
                WelcomeAction(title: "Open Folder…", symbol: "folder", shortcut: "⇧⌘O") {
                    model.showOpenFolderPanel()
                }
                if CloudLocation.iCloudDriveURL != nil {
                    WelcomeAction(title: "Open iCloud Drive Folder…", symbol: "icloud", shortcut: "") {
                        model.showOpeniCloudFolderPanel()
                    }
                }
            }

            if !recentItems.isEmpty {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text("Recent")
                        .font(.system(size: TextSize.xs, weight: .semibold))
                        .foregroundStyle(Color.textSecondary)
                        .padding(.horizontal, Space.s3)
                    ForEach(recentItems, id: \.url) { item in
                        RecentRow(url: item.url, isFolder: item.isFolder)
                    }
                }
            }
        }
        .frame(maxWidth: Layout.welcomeWidth)
        .padding(Space.s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.editorBackground)
    }

    private var recentItems: [(url: URL, isFolder: Bool)] {
        let folders = model.session.recentWorkspaces.prefix(4).map { ($0, true) }
        let files = model.session.recentFiles.prefix(6).map { ($0, false) }
        return (folders + files).map { (url: $0.0, isFolder: $0.1) }
    }
}

private struct WelcomeAction: View {
    @Environment(\.colorTheme) private var colorTheme
    let title: LocalizedStringKey
    let symbol: String
    let shortcut: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s3) {
                Image(systemName: symbol)
                    .font(.system(size: IconSize.standalone))
                    .foregroundStyle(Color.themeAccent(colorTheme))
                    .frame(width: Space.s6)
                Text(title)
                    .font(.system(size: TextSize.base))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Text(shortcut)
                    .font(.system(size: TextSize.sm))
                    .foregroundStyle(Color.textTertiary)
            }
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s2)
            .background(
                RoundedRectangle(cornerRadius: Radius.medium)
                    .fill(isHovering ? Color.surfaceMuted : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct RecentRow: View {
    @Environment(AppModel.self) private var model
    let url: URL
    let isFolder: Bool
    @State private var isHovering = false

    var body: some View {
        Button {
            model.openRecent(url)
        } label: {
            HStack(spacing: Space.s3) {
                Image(systemName: isFolder ? "folder" : "doc.text")
                    .font(.system(size: IconSize.inline))
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: Space.s6)
                VStack(alignment: .leading, spacing: 0) {
                    Text(url.lastPathComponent)
                        .font(.system(size: TextSize.sm))
                        .foregroundStyle(Color.textPrimary)
                    Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: TextSize.xs))
                        .foregroundStyle(Color.textTertiary)
                        .truncationMode(.middle)
                }
                .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s1)
            .background(
                RoundedRectangle(cornerRadius: Radius.medium)
                    .fill(isHovering ? Color.surfaceMuted : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Reveal in Finder") { SystemIntegration.revealInFinder(url) }
            Button("Remove from Recent") { model.session.removeRecent(url) }
        }
    }
}

// MARK: - Quick Open

struct QuickOpenView: View {
    @Environment(\.colorTheme) private var colorTheme
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var candidates: [URL] = []
    @State private var selectedIndex = 0
    @FocusState private var isFocused: Bool

    var body: some View {
        let matches = FuzzyMatcher.rank(query: query, urls: candidates, root: model.workspace.rootURL, limit: 50)

        VStack(spacing: 0) {
            TextField("Open file by name", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: TextSize.lg))
                .padding(Space.s4)
                .focused($isFocused)
                .onSubmit { open(matches) }
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
                ContentUnavailableView("No Matching Files", systemImage: "doc.text.magnifyingglass")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(Array(matches.enumerated()), id: \.element.url) { index, match in
                        HStack(spacing: Space.s3) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(Color.textSecondary)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(match.url.lastPathComponent)
                                    .font(.system(size: TextSize.sm, weight: .semibold))
                                    .foregroundStyle(Color.textPrimary)
                                Text(match.relativeDirectory)
                                    .font(.system(size: TextSize.xs))
                                    .foregroundStyle(Color.textTertiary)
                            }
                            .lineLimit(1)
                            Spacer()
                        }
                        .padding(.vertical, Space.s1)
                        .contentShape(Rectangle())
                        .listRowBackground(index == selectedIndex ? Color.themeSelection(colorTheme) : Color.clear)
                        .id(index)
                        .onTapGesture {
                            selectedIndex = index
                            open(matches)
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
        .task {
            var files = await model.workspace.allMarkdownFiles()
            let known = Set(files.map(\.standardizedFileURL))
            let open = model.documents.documents.compactMap { $0.fileReference?.url }.filter { !known.contains($0) }
            files.append(contentsOf: open)
            candidates = files
            isFocused = true
        }
    }

    private func open(_ matches: [FuzzyMatcher.Match]) {
        guard matches.indices.contains(selectedIndex) else { return }
        let url = matches[selectedIndex].url
        dismiss()
        Task { await model.openDocument(url) }
    }
}

enum FuzzyMatcher {
    struct Match {
        let url: URL
        let score: Int
        let relativeDirectory: String
    }

    /// 子序列模糊匹配：连续命中、文件名命中、词首命中加分。
    static func rank(query: String, urls: [URL], root: URL?, limit: Int) -> [Match] {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        var matches: [Match] = []
        matches.reserveCapacity(min(urls.count, limit * 4))

        for url in urls {
            let relative: String
            if let root, url.path.hasPrefix(root.path + "/") {
                relative = String(url.path.dropFirst(root.path.count + 1))
            } else {
                relative = (url.path as NSString).abbreviatingWithTildeInPath
            }
            let directory = (relative as NSString).deletingLastPathComponent

            guard !needle.isEmpty else {
                matches.append(Match(url: url, score: 0, relativeDirectory: directory))
                continue
            }
            guard let score = score(needle: needle, haystack: Array(relative.lowercased()), fileNameStart: relative.count - url.lastPathComponent.count) else { continue }
            matches.append(Match(url: url, score: score, relativeDirectory: directory))
        }

        matches.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        return Array(matches.prefix(limit))
    }

    /// 通用子序列匹配（命令面板使用）。
    static func score(needle: [Character], in text: String) -> Int? {
        score(needle: needle, haystack: Array(text), fileNameStart: 0)
    }

    private static func score(needle: [Character], haystack: [Character], fileNameStart: Int) -> Int? {
        var score = 0
        var needleIndex = 0
        var previousMatch = -2
        for (index, character) in haystack.enumerated() where needleIndex < needle.count {
            guard character == needle[needleIndex] else { continue }
            score += 1
            if index == previousMatch + 1 { score += 4 }
            if index >= fileNameStart { score += 2 }
            if index == 0 || ["/", "-", "_", " ", "."].contains(haystack[index - 1]) { score += 3 }
            previousMatch = index
            needleIndex += 1
        }
        return needleIndex == needle.count ? score : nil
    }
}

// MARK: - Compare

/// 逐行差异列表：比较磁盘版本与查看历史版本共用。`header` 显示在列表顶部。
struct DiffLinesView<Header: View>: View {
    let lines: [CompareView.DiffLine]
    @ViewBuilder var header: () -> Header

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                header()
                ForEach(lines) { line in
                    HStack(spacing: Space.s2) {
                        Text(verbatim: symbol(line.kind))
                            .foregroundStyle(Color.textTertiary)
                            .frame(width: Space.s4)
                        Text(verbatim: line.text.isEmpty ? " " : line.text)
                            .foregroundStyle(Color.textPrimary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.system(size: TextSize.sm, design: .monospaced))
                    .padding(.horizontal, Space.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(line.kind))
                }
            }
            .padding(.vertical, Space.s2)
        }
    }

    private func symbol(_ kind: CompareView.DiffLine.Kind) -> String {
        switch kind {
        case .same: ""
        case .removed: "−"
        case .added: "+"
        }
    }

    private func background(_ kind: CompareView.DiffLine.Kind) -> Color {
        switch kind {
        case .same: .clear
        case .removed: .diffRemoved
        case .added: .diffAdded
        }
    }
}

extension DiffLinesView where Header == EmptyView {
    init(lines: [CompareView.DiffLine]) {
        self.init(lines: lines) { EmptyView() }
    }
}

struct CompareView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: CompareRequest
    @State private var lines: [DiffLine] = []

    struct DiffLine: Identifiable {
        enum Kind { case same, removed, added }
        let id: Int
        let kind: Kind
        let text: String
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s4) {
                Text("Compare “\(request.document.displayName)”")
                    .font(.system(size: TextSize.lg, weight: .semibold))
                Spacer()
                Label("On Disk", systemImage: "minus")
                    .foregroundStyle(Color.statusError)
                Label("Yours", systemImage: "plus")
                    .foregroundStyle(Color.statusSuccess)
            }
            .font(.system(size: TextSize.sm))
            .padding(Space.s4)

            Divider()

            DiffLinesView(lines: lines)

            Divider()

            HStack(spacing: Space.s2) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use Disk Version") {
                    model.reloadFromDisk(request.document)
                    dismiss()
                }
                Button("Keep Mine") {
                    model.keepLocalVersion(request.document)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(Space.s4)
        }
        .frame(width: Layout.compareWidth, height: Layout.compareHeight)
        .task {
            let disk = request.diskText
            let local = request.localText
            lines = await Task.detached { Self.diff(old: disk, new: local) }.value
        }
    }

    nonisolated static func diff(old: String, new: String) -> [DiffLine] {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let difference = newLines.difference(from: oldLines)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var result: [DiffLine] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if oldIndex < oldLines.count, removed.contains(oldIndex) {
                result.append(DiffLine(id: result.count, kind: .removed, text: oldLines[oldIndex]))
                oldIndex += 1
            } else if newIndex < newLines.count, inserted.contains(newIndex) {
                result.append(DiffLine(id: result.count, kind: .added, text: newLines[newIndex]))
                newIndex += 1
            } else if newIndex < newLines.count {
                result.append(DiffLine(id: result.count, kind: .same, text: newLines[newIndex]))
                oldIndex += 1
                newIndex += 1
            } else {
                oldIndex += 1
            }
        }
        return result
    }
}
