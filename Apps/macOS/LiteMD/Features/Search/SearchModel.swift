import Foundation
import LiteMDApplication
import LiteMDDomain
import Observation

/// Workspace 搜索界面状态。输入防抖，新的查询会取消旧任务（spec §157）。
@MainActor
@Observable
final class SearchModel {
    var query = "" {
        didSet { if query != oldValue { schedule() } }
    }

    var isCaseSensitive = false {
        didSet { if isCaseSensitive != oldValue { schedule() } }
    }

    private(set) var results: [FileSearchResult] = []
    private(set) var isSearching = false

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
