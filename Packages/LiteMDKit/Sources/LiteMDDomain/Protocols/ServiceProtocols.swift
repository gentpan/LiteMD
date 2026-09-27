import Foundation

/// 从磁盘读取并解码后的文档。
public struct LoadedText: Sendable {
    public var text: String
    public var encoding: TextEncoding
    public var lineEnding: LineEnding
    public var diskRevision: DiskRevision
    public var identity: FileIdentity?

    public init(text: String, encoding: TextEncoding, lineEnding: LineEnding, diskRevision: DiskRevision, identity: FileIdentity?) {
        self.text = text
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.diskRevision = diskRevision
        self.identity = identity
    }
}

/// 文件系统能力。只处理文件，不解析 Markdown、不决定 Autosave（spec §117）。
public protocol FileSystem: Sendable {
    func readText(at url: URL) async throws(LiteMDError) -> LoadedText
    /// iCloud 文件：先下载到本地再返回。已下载或非 iCloud 文件立即返回。
    func ensureDownloaded(at url: URL) async throws(LiteMDError)
    func cloudStatus(at url: URL) async -> CloudStatus
    /// iCloud 在多设备同时编辑时产生的冲突版本。
    func cloudConflicts(at url: URL) async -> [VersionSnapshot]
    /// 保留当前文件内容，把其余冲突版本标记为已解决并删除。
    func resolveCloudConflicts(at url: URL) async
    func readData(at url: URL) async throws(LiteMDError) -> Data

    /// 原子写入：temporary → flush → fsync → atomic replace（spec §81）。
    func writeText(_ text: String, encoding: TextEncoding, lineEnding: LineEnding, to url: URL) async throws(LiteMDError) -> DiskRevision

    /// 文件不存在时返回 nil。
    func diskRevision(at url: URL, includeHash: Bool) async throws(LiteMDError) -> DiskRevision?
    func identity(at url: URL) async -> FileIdentity?
    func itemExists(at url: URL) async -> Bool
    func isDirectory(at url: URL) async -> Bool

    func contentsOfDirectory(at url: URL, rules: WorkspaceIgnoreRules) async throws(LiteMDError) -> [WorkspaceEntry]
    /// 递归列出 Markdown 文件，不读取正文。
    func markdownFiles(under url: URL, rules: WorkspaceIgnoreRules) async throws(LiteMDError) -> [URL]

    /// 目标已存在时失败，绝不覆盖。
    func createFile(at url: URL, contents: Data) async throws(LiteMDError)
    func createDirectory(at url: URL) async throws(LiteMDError)
    /// 目标已存在时失败，绝不覆盖。
    func moveItem(from source: URL, to destination: URL) async throws(LiteMDError)
    /// 目标已存在时失败，绝不覆盖。
    func copyItem(from source: URL, to destination: URL) async throws(LiteMDError)
    /// 移到废纸篓而不是永久删除。
    func trashItem(at url: URL) async throws(LiteMDError)
}

public extension FileSystem {
    /// 默认实现：不处理 iCloud。
    func ensureDownloaded(at url: URL) async throws(LiteMDError) {}
    func cloudStatus(at url: URL) async -> CloudStatus { .local }
    func cloudConflicts(at url: URL) async -> [VersionSnapshot] { [] }
    func resolveCloudConflicts(at url: URL) async {}
}

public struct MarkdownParseOptions: Sendable, Equatable {
    public init() {}
}

public protocol MarkdownParsing: Sendable {
    func parse(_ text: String, documentID: DocumentID, revision: Int, options: MarkdownParseOptions) async -> ParseResult
}

public struct RecoveryEntry: Codable, Identifiable, Sendable, Equatable {
    public var documentID: DocumentID
    public var originalURL: URL?
    public var displayName: String
    /// 崩溃前对原文件的认知（磁盘版本、编码、换行符），恢复时一并还原。
    public var knownDiskRevision: DiskRevision?
    public var encoding: TextEncoding
    public var lineEnding: LineEnding
    public var timestamp: Date

    public init(
        documentID: DocumentID,
        originalURL: URL?,
        displayName: String,
        knownDiskRevision: DiskRevision?,
        encoding: TextEncoding,
        lineEnding: LineEnding,
        timestamp: Date
    ) {
        self.documentID = documentID
        self.originalURL = originalURL
        self.displayName = displayName
        self.knownDiskRevision = knownDiskRevision
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.timestamp = timestamp
    }

    public var id: DocumentID { documentID }
}

/// Crash Recovery 存储。与正式保存完全独立（spec §134）。
public protocol RecoveryStoring: Sendable {
    func entries() async -> [RecoveryEntry]
    func content(for id: DocumentID) async throws(LiteMDError) -> String
    func store(_ entry: RecoveryEntry, content: String) async throws(LiteMDError)
    func remove(_ id: DocumentID) async
    func removeAll() async
}

/// 覆盖前备份（spec §33 Local History 的第一步）：文件被 LiteMD 覆盖前保存磁盘上的原内容。
public protocol VersionHistoryStoring: Sendable {
    func storeSnapshot(of url: URL, data: Data, date: Date) async
    func snapshots(for url: URL) async -> [VersionSnapshot]
}

public struct VersionSnapshot: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// 版本来源：LiteMD 覆盖前保存的副本，或 iCloud 的冲突版本。
    public enum Origin: String, Codable, Sendable {
        case history
        case cloudConflict
    }

    public var id: String { fileURL.path }
    public var originalURL: URL
    public var fileURL: URL
    public var date: Date
    public var byteCount: Int64
    public var origin: Origin
    /// iCloud 冲突版本所在的设备名。
    public var deviceName: String?

    public init(originalURL: URL, fileURL: URL, date: Date, byteCount: Int64 = 0, origin: Origin = .history, deviceName: String? = nil) {
        self.originalURL = originalURL
        self.fileURL = fileURL
        self.date = date
        self.byteCount = byteCount
        self.origin = origin
        self.deviceName = deviceName
    }
}

/// 应用状态（Recent、Session、UI State）的持久化。不保存 Markdown 正文。
public protocol StateStoring: Sendable {
    func load<Value: Codable & Sendable>(_ type: Value.Type, key: String) async -> Value?
    func save<Value: Codable & Sendable>(_ value: Value, key: String) async
}

/// 平台文件监控。事件在主线程回调。
@MainActor
public protocol FileWatching: AnyObject {
    var eventHandler: (([FileEvent]) -> Void)? { get set }
    func setWatchedDirectories(_ urls: Set<URL>)
}
