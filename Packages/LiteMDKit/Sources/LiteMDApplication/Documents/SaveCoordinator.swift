import Foundation
import LiteMDDomain

public enum SavePolicy: Sendable, Equatable {
    /// 只有 Dirty 时才写入（手动保存、Autosave）。
    case ifDirty
    /// 无论是否 Dirty 都写入（Save As）。
    case always
    /// 用户明确选择“保留我的版本”后覆盖外部修改。
    case overwriteExternalChanges
}

/// 开始保存时的快照（spec §100）。保存期间用户可以继续输入。
struct SaveSnapshot: Sendable {
    var documentID: DocumentID
    var revision: Int
    var content: String
    var fileReference: FileReference
    var knownDiskRevision: DiskRevision?
}

/// 所有保存都经过这里（spec §99、§102）。
///
/// - 同一 Document 同一时间只有一个写入（Single Flight）；
/// - 等待中的保存在前一个完成后只保存最新 revision，中间 revision 被跳过；
/// - 写入前比较磁盘版本，不一致进入 Conflict，绝不静默覆盖。
@MainActor
final class SaveCoordinator {
    private let fileSystem: any FileSystem
    private let history: (any VersionHistoryStoring)?
    private let snapshotInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var running: [DocumentID: Task<Result<Void, LiteMDError>, Never>] = [:]
    /// 每个文件最近一次保存历史版本的时间。
    private var lastSnapshotDates: [String: Date] = [:]
    /// 历史版本随重命名 / 移动搬迁的任务链。之后的读写都要排在它后面。
    private var historyMigration: Task<Void, Never>?

    var didSave: ((Document) -> Void)?

    /// - Parameter snapshotInterval: 同一文件两次历史版本之间的最短间隔。本次运行中第一次覆盖、
    ///   以及用户选择覆盖外部修改时总会保存。
    init(fileSystem: any FileSystem, history: (any VersionHistoryStoring)? = nil, snapshotInterval: TimeInterval = 600, now: @escaping @Sendable () -> Date = Date.init) {
        self.fileSystem = fileSystem
        self.history = history
        self.snapshotInterval = snapshotInterval
        self.now = now
    }

    func isSaving(_ document: Document) -> Bool {
        running[document.id] != nil
    }

    func waitUntilIdle(_ document: Document) async {
        while let task = running[document.id] {
            _ = await task.value
        }
    }

    func save(_ document: Document, policy: SavePolicy) async throws(LiteMDError) {
        await waitUntilIdle(document)
        // 等待期间，其他调用者可能已经保存了最新 revision。
        if policy == .ifDirty, !document.isDirty { return }

        let task = Task { @MainActor [self] in
            defer { running[document.id] = nil }
            return await performSave(document, policy: policy)
        }
        running[document.id] = task
        try await task.value.get()
    }

    private func performSave(_ document: Document, policy: SavePolicy) async -> Result<Void, LiteMDError> {
        guard let reference = document.fileReference else {
            return .failure(LiteMDError(kind: .save, reason: .requiresSavedDocument, fileName: document.displayName))
        }
        if policy != .overwriteExternalChanges, document.conflict.isConflict {
            let reason: LiteMDError.Reason = document.conflict == .externalDeleted ? .externalDeletion : .externalModification
            return .failure(LiteMDError(kind: .conflict, reason: reason, fileName: reference.displayName))
        }
        if policy == .ifDirty, !document.isDirty {
            return .success(())
        }

        let snapshot = SaveSnapshot(
            documentID: document.id,
            revision: document.revision,
            content: document.buffer.snapshot(),
            fileReference: reference,
            knownDiskRevision: document.knownDiskRevision
        )
        document.saveActivity = .saving

        do throws(LiteMDError) {
            if policy != .overwriteExternalChanges, let known = snapshot.knownDiskRevision {
                try await verifyDiskUnchanged(snapshot.fileReference, known: known)
            }

            await snapshotBeforeOverwrite(snapshot.fileReference.url, force: policy == .overwriteExternalChanges)

            // 文档认为文件存在时，写入期间文件被移走或删除要报冲突，而不是在旧路径把它重新创建出来。
            // 首次保存、Save As、用户选择“保留我的版本”时允许创建。
            let written = try await fileSystem.writeText(
                snapshot.content,
                encoding: snapshot.fileReference.encoding,
                lineEnding: snapshot.fileReference.lineEnding,
                to: snapshot.fileReference.url,
                requireExisting: snapshot.knownDiskRevision != nil && policy != .overwriteExternalChanges
            )

            // 保存期间文件可能被重命名；只有仍指向同一位置时才更新磁盘版本。
            if document.fileReference?.url == snapshot.fileReference.url {
                document.knownDiskRevision = written
            }
            // 保存的是快照的 revision。保存期间继续输入的内容仍然是 Dirty（spec §100）。
            document.savedRevision = max(document.savedRevision, snapshot.revision)
            if policy == .overwriteExternalChanges {
                document.conflict = .none
            }
            document.saveActivity = .idle
            didSave?(document)
            return .success(())
        } catch {
            if error.kind == .conflict {
                // 保存期间文档已跟随重命名 / 移动到新位置时，旧路径上的冲突不再适用：保持 Dirty，
                // 由跟随移动时重新安排的自动保存写入新位置。
                if document.fileReference?.url == snapshot.fileReference.url {
                    document.conflict = error.reason == .externalDeletion ? .externalDeleted : .externalModified
                }
                document.saveActivity = .idle
            } else {
                document.saveActivity = .failed(error)
            }
            return .failure(error)
        }
    }

    /// 文件或文件夹被重命名 / 移动后调用，让历史版本与保存间隔跟随新路径。
    func itemMoved(from oldURL: URL, to newURL: URL) {
        let oldPath = oldURL.standardizedFileURL.path
        let newPath = newURL.standardizedFileURL.path
        for (path, date) in lastSnapshotDates where path == oldPath || path.hasPrefix(oldPath + "/") {
            lastSnapshotDates[path] = nil
            lastSnapshotDates[newPath + path.dropFirst(oldPath.count)] = date
        }

        guard let history else { return }
        let previous = historyMigration
        historyMigration = Task {
            await previous?.value
            await history.moveSnapshots(from: oldURL, to: newURL)
        }
    }

    /// 等待进行中的历史搬迁，保证随后读到、写入的是新路径下的历史。
    func waitForHistoryMigration() async {
        await historyMigration?.value
    }

    private func snapshotBeforeOverwrite(_ url: URL, force: Bool) async {
        guard let history else { return }
        await waitForHistoryMigration()
        let path = url.standardizedFileURL.path
        let date = now()
        if !force, let last = lastSnapshotDates[path], date.timeIntervalSince(last) < snapshotInterval { return }
        guard let data = try? await fileSystem.readData(at: url) else { return }
        await history.storeSnapshot(of: url, data: data, date: date)
        lastSnapshotDates[path] = date
    }

    /// 先比较修改时间与大小；不一致时再比较内容 Hash（spec §91）。
    private func verifyDiskUnchanged(_ reference: FileReference, known: DiskRevision) async throws(LiteMDError) {
        let name = reference.displayName
        guard let current = try await fileSystem.diskRevision(at: reference.url, includeHash: false) else {
            throw LiteMDError(kind: .conflict, reason: .externalDeletion, fileName: name)
        }
        if current.matchesMetadata(known) { return }

        guard let hashed = try await fileSystem.diskRevision(at: reference.url, includeHash: true) else {
            throw LiteMDError(kind: .conflict, reason: .externalDeletion, fileName: name)
        }
        // 只有元数据变化（例如 touch）而内容相同，可以安全写入。
        if hashed.matchesContent(known) == true { return }
        throw LiteMDError(kind: .conflict, reason: .externalModification, fileName: name)
    }
}
