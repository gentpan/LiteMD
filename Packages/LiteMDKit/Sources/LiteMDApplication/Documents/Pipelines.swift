import Foundation
import LiteMDDomain

/// Autosave 不是 FileSystem 功能（spec §103）：观察变化 → 防抖 → 检查条件 → 请求保存。
@MainActor
final class AutosaveCoordinator {
    var isEnabled = true
    var delay: Duration = .milliseconds(500)
    /// 持续输入时的最长等待，避免一直不保存。
    var maximumDelay: Duration = .seconds(5)

    private let saveCoordinator: SaveCoordinator
    private let clock = ContinuousClock()
    private var pending: [DocumentID: Task<Void, Never>] = [:]
    private var firstPendingChange: [DocumentID: ContinuousClock.Instant] = [:]

    init(saveCoordinator: SaveCoordinator) {
        self.saveCoordinator = saveCoordinator
    }

    func documentDidChange(_ document: Document) {
        guard isEnabled, document.fileReference != nil, !document.conflict.isConflict else { return }

        pending[document.id]?.cancel()
        let now = clock.now
        let first = firstPendingChange[document.id] ?? now
        firstPendingChange[document.id] = first
        let remaining = maximumDelay - first.duration(to: now)
        let wait = max(.zero, min(delay, remaining))

        switch document.saveActivity {
        case .idle, .failed: document.saveActivity = .scheduled
        case .scheduled, .saving: break
        }

        pending[document.id] = Task { [weak self, weak document] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, let document else { return }
            await self.fire(document)
        }
    }

    private func fire(_ document: Document) async {
        pending[document.id] = nil
        let canSave = isEnabled
            && document.isDirty
            && document.fileReference != nil
            && !document.conflict.isConflict
            && document.lifecycle == .ready

        guard canSave else {
            firstPendingChange[document.id] = nil
            if document.saveActivity == .scheduled { document.saveActivity = .idle }
            return
        }
        // IME 组合期间不保存，等 Composition Commit 后的变化通知再触发（spec §104）。
        guard !document.isComposing else { return }

        firstPendingChange[document.id] = nil
        try? await saveCoordinator.save(document, policy: .ifDirty)
    }

    func cancel(_ document: Document) {
        pending.removeValue(forKey: document.id)?.cancel()
        firstPendingChange[document.id] = nil
        if document.saveActivity == .scheduled { document.saveActivity = .idle }
    }
}

/// 异步解析（spec §97）：结果 revision 落后于文档 revision 时直接丢弃。
@MainActor
final class ParseCoordinator {
    private let parser: any MarkdownParsing
    var baseDelay: Duration = .milliseconds(150)
    private var tasks: [DocumentID: Task<Void, Never>] = [:]

    init(parser: any MarkdownParsing) {
        self.parser = parser
    }

    func schedule(_ document: Document, immediately: Bool = false) {
        tasks[document.id]?.cancel()
        // 大文档解析更慢，适当加长防抖，最多 1 秒。
        let sizePenalty = Duration.milliseconds(document.buffer.length / 2_000)
        let delay = immediately ? .zero : min(.seconds(1), baseDelay + sizePenalty)
        let parser = self.parser

        tasks[document.id] = Task { [weak document] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let document, !document.isComposing else { return }
            let revision = document.revision
            let text = document.buffer.snapshot()
            let result = await parser.parse(text, documentID: document.id, revision: revision, options: MarkdownParseOptions())
            guard !Task.isCancelled, result.revision == document.revision else { return }
            document.parseResult = result
        }
    }

    func cancel(_ document: Document) {
        tasks.removeValue(forKey: document.id)?.cancel()
    }
}

/// Crash Recovery（spec §134–135）。独立于正式保存，按固定间隔节流写入快照。
@MainActor
final class RecoveryCoordinator {
    private let store: any RecoveryStoring
    var interval: Duration = .seconds(2)
    private var pending: [DocumentID: Task<Void, Never>] = [:]
    /// 每个文档的存储操作串行执行，保证“写入 → 删除”的顺序。
    private var chains: [DocumentID: Task<Void, Never>] = [:]

    init(store: any RecoveryStoring) {
        self.store = store
    }

    func documentDidChange(_ document: Document) {
        // 节流而非防抖：持续输入时也至少每个 interval 写一次。
        guard pending[document.id] == nil else { return }
        let interval = self.interval
        pending[document.id] = Task { [weak self, weak document] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, let self, let document else { return }
            self.pending[document.id] = nil
            self.snapshot(document)
        }
    }

    func snapshot(_ document: Document) {
        guard document.isDirty, document.lifecycle == .ready else { return }
        let entry = RecoveryEntry(
            documentID: document.id,
            originalURL: document.fileReference?.url,
            displayName: document.displayName,
            knownDiskRevision: document.knownDiskRevision,
            encoding: document.fileReference?.encoding ?? .utf8,
            lineEnding: document.fileReference?.lineEnding ?? .lf,
            timestamp: Date()
        )
        let content = document.buffer.snapshot()
        document.recoveryRevision = document.revision
        let store = self.store
        enqueue(document.id) {
            try? await store.store(entry, content: content)
        }
    }

    func documentSaved(_ document: Document) {
        guard let recoveryRevision = document.recoveryRevision, document.savedRevision >= recoveryRevision else { return }
        document.recoveryRevision = nil
        remove(document.id)
    }

    func documentClosed(_ document: Document) {
        pending.removeValue(forKey: document.id)?.cancel()
        document.recoveryRevision = nil
        remove(document.id)
    }

    func remove(_ id: DocumentID) {
        let store = self.store
        enqueue(id) {
            await store.remove(id)
        }
    }

    func waitForPendingWrites() async {
        for task in chains.values {
            await task.value
        }
    }

    private func enqueue(_ id: DocumentID, _ operation: @escaping @Sendable () async -> Void) {
        let previous = chains[id]
        chains[id] = Task {
            await previous?.value
            await operation()
        }
    }
}
