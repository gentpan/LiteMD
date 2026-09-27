import AppKit
import LiteMDApplication
import LiteMDDomain
import Observation

/// Workspace 搜索界面状态。输入防抖，新的查询会取消旧任务（spec §157）。
@MainActor
@Observable
final class SearchModel {
    var query = "" {
        didSet { if query != oldValue { replaceSummary = nil; schedule() } }
    }

    var isCaseSensitive = false {
        didSet { if isCaseSensitive != oldValue { replaceSummary = nil; schedule() } }
    }

    /// 替换框是否展开，以及替换成的文字。
    var showsReplace = false
    var replacement = "" {
        didSet { if replacement != oldValue { replaceSummary = nil } }
    }

    private(set) var results: [FileSearchResult] = []
    private(set) var isSearching = false
    private(set) var isReplacing = false
    /// 上一次“全部替换”的结果：替换了几处、改了几个文件。
    private(set) var replaceSummary: (occurrences: Int, files: Int)?

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var task: Task<Void, Never>?

    var totalMatches: Int {
        results.reduce(0) { $0 + $1.matches.count }
    }

    /// 换了文件夹：旧结果作废，保留搜索词并在新文件夹里重新搜，
    /// 否则侧栏会显示着搜索词却是“无结果”，再搜同一个词也不会触发。
    func reset() {
        results = []
        schedule()
    }

    func refresh() {
        schedule()
    }

    // MARK: Replace

    /// 在整个文件夹里全部替换。先按搜索的同一套规则统计（不受结果列表的显示上限影响），确认后执行：
    /// 已打开的文档通过编辑器替换，可以撤销；其他文件替换前的版本存进历史，编码与换行符保持原样。
    func replaceAll() {
        guard let model, !query.isEmpty, !isReplacing else { return }
        let searchQuery = SearchQuery(text: query, caseSensitive: isCaseSensitive)
        let replacement = self.replacement
        isReplacing = true
        task?.cancel()

        Task { [weak self] in
            defer { self?.isReplacing = false }
            let counts = await Self.countMatches(searchQuery, model: model)
            let occurrences = counts.values.reduce(0, +)
            guard let self, occurrences > 0 else {
                self?.replaceSummary = (0, 0)
                return
            }

            let choice = SystemIntegration.runAlert(
                title: String(localized: "Replace “\(searchQuery.text)” with “\(replacement)”?"),
                message: String(localized: "\(occurrences) occurrences in \(counts.count) files will be replaced. Changes to open documents can be undone; other files keep their previous version in Version History."),
                buttons: [String(localized: "Cancel"), String(localized: "Replace All")]
            )
            guard choice == 1 else { return }

            var replaced = 0
            var changedFiles = 0
            var failures: [String] = []
            for url in counts.keys.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
                let count: Int
                if let document = model.documents.documents.first(where: { $0.fileReference?.url.standardizedFileURL == url }) {
                    // 与磁盘版本冲突的文档先要用户处理冲突，不替换。
                    guard !document.conflict.isConflict else {
                        failures.append(String(localized: "“\(url.lastPathComponent)” has a conflict with the version on disk."))
                        continue
                    }
                    count = model.editor(for: document).replaceAll(searchQuery, with: replacement)
                } else {
                    do throws(LiteMDError) {
                        count = try await model.documents.replaceText(inFileAt: url, searchQuery, with: replacement)
                    } catch {
                        failures.append("\(url.lastPathComponent): \(error.localizedMessage)")
                        continue
                    }
                }
                replaced += count
                if count > 0 { changedFiles += 1 }
            }

            self.replaceSummary = (replaced, changedFiles)
            self.schedule()
            if !failures.isEmpty {
                SystemIntegration.runAlert(
                    title: String(localized: "Some files could not be changed."),
                    message: String(localized: "The other files were replaced. The files listed below were left unchanged."),
                    buttons: [String(localized: "OK")],
                    details: failures.joined(separator: "\n")
                )
            }
        }
    }

    /// 每个文件的匹配数：文件夹里的全部 Markdown 文件，加上文件夹之外已打开的文档；打开的文档用编辑器里的内容。
    private static func countMatches(_ query: SearchQuery, model: AppModel) async -> [URL: Int] {
        var files = await model.workspace.allMarkdownFiles().map(\.standardizedFileURL)
        var openDocuments: [URL: String] = [:]
        for document in model.documents.documents {
            guard let url = document.fileReference?.url.standardizedFileURL else { continue }
            openDocuments[url] = document.text
        }
        let known = Set(files)
        files.append(contentsOf: openDocuments.keys.filter { !known.contains($0) })

        var options = WorkspaceSearcher.Options()
        options.maximumMatchesPerFile = .max
        options.maximumTotalMatches = .max
        var counts: [URL: Int] = [:]
        for await result in model.searcher.search(query, files: files, openDocuments: openDocuments, options: options) {
            counts[result.url.standardizedFileURL] = result.matches.count
        }
        return counts
    }

    private func schedule() {
        task?.cancel()
        let text = query
        let caseSensitive = isCaseSensitive
        guard !text.isEmpty else {
            results = []
            isSearching = false
            return
        }

        // 防抖期间就进入“搜索中”，避免先闪现“无结果”。
        isSearching = true
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, let model = self.model else { return }

            var files = await model.workspace.allMarkdownFiles().map(\.standardizedFileURL)
            var openDocuments: [URL: String] = [:]
            for document in model.documents.documents {
                guard let url = document.fileReference?.url.standardizedFileURL else { continue }
                openDocuments[url] = document.text
            }
            let known = Set(files)
            files.append(contentsOf: openDocuments.keys.filter { !known.contains($0) })
            guard !Task.isCancelled else { return }

            var collected: [FileSearchResult] = []
            let stream = model.searcher.search(SearchQuery(text: text, caseSensitive: caseSensitive), files: files, openDocuments: openDocuments)
            for await result in stream {
                if Task.isCancelled { break }
                collected.append(result)
            }
            guard !Task.isCancelled else { return }

            self.results = collected.sorted {
                $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
            }
            self.isSearching = false
        }
    }
}

@MainActor
extension AppModel {
    /// 打开侧栏搜索并展开替换框。
    func showReplaceInFolder() {
        search.showsReplace = true
        showSidebar(.search)
    }
}
