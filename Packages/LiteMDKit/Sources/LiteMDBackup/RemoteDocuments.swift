import CryptoKit
import Foundation
import LiteMDDomain

/// S3 中的一篇 Markdown 文档。
public struct RemoteDocument: Identifiable, Hashable, Sendable {
    public var key: String
    /// 小写、去掉引号的 ETag。
    public var eTag: String
    public var size: Int64
    public var lastModified: Date?

    public var id: String { key }

    public var name: String {
        key.split(separator: "/").last.map(String.init) ?? key
    }

    public init(key: String, eTag: String, size: Int64 = 0, lastModified: Date? = nil) {
        self.key = key
        self.eTag = eTag.lowercased()
        self.size = size
        self.lastModified = lastModified
    }
}

/// 本地文件与 S3 对象的关联：记录最近一次下载或上传时两边的内容指纹，
/// 用来判断本地有没有未上传的修改、远端在这之后有没有被改过。
public struct RemoteDocumentLink: Codable, Hashable, Sendable {
    public var endpoint: String
    public var bucket: String
    public var key: String
    /// 最近一次下载或上传时远端的 ETag。
    public var remoteETag: String
    /// 最近一次下载或上传时本地内容的 MD5（十六进制）。
    public var localMD5: String
    public var syncedAt: Date

    public init(endpoint: String, bucket: String, key: String, remoteETag: String, localMD5: String, syncedAt: Date = Date()) {
        self.endpoint = endpoint
        self.bucket = bucket
        self.key = key
        self.remoteETag = remoteETag.lowercased()
        self.localMD5 = localMD5
        self.syncedAt = syncedAt
    }
}

public enum RemoteDocumentState: Equatable, Sendable {
    case notDownloaded
    case synced
    /// 本地有未上传的修改，远端没变。
    case localChanges
    /// 远端在下载之后被改过，本地没改。
    case remoteChanges
    case bothChanged
}

/// 浏览桶里的 Markdown 文档：下载到本地编辑，需要时再上传覆盖。
///
/// 安全规则：
/// - 对象键含 `..`、绝对路径或空路径段时不映射到本地，远端内容写不到下载目录之外；
/// - 下载内容与 ETag（MD5）不一致时视为失败；
/// - 是否覆盖远端由调用方根据 `currentETag` 决定，这里只负责执行。
public struct RemoteDocumentStore: Sendable {
    public let client: S3Client

    public init(client: S3Client) {
        self.client = client
    }

    /// 列出整个桶里的 Markdown 文档（`.md`、`.markdown`），按键排序。
    public func documents() async throws(S3Error) -> [RemoteDocument] {
        try await client.listObjects(prefix: "")
            .filter { Self.isMarkdown($0.key) }
            .map { RemoteDocument(key: $0.key, eTag: $0.eTag, size: $0.size, lastModified: $0.lastModified) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }

    public func download(_ key: String) async throws(S3Error) -> (data: Data, eTag: String) {
        let object = try await client.getObject(key: key)
        if let expected = object.contentMD5, Self.md5(object.data) != expected {
            throw S3Error.invalidResponse
        }
        return (object.data, object.eTag)
    }

    /// 远端当前的 ETag；对象已被删除时返回 nil。
    public func currentETag(of key: String) async throws(S3Error) -> String? {
        try await client.headObject(key: key)
    }

    /// 上传并返回新的 ETag。
    public func upload(_ data: Data, to key: String) async throws(S3Error) -> String {
        try await client.putObject(key: key, data: data, contentType: "text/markdown; charset=utf-8").lowercased()
    }

    public static func isMarkdown(_ key: String) -> Bool {
        guard !key.hasSuffix("/") else { return false }
        let ext = (key as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    /// 对象键对应的本地位置：`root/<键的各段>`。键不安全时返回 nil。
    public static func localURL(for key: String, in root: URL) -> URL? {
        guard let segments = RestoreEngine.safeRelativePath(key) else { return nil }
        let root = root.standardizedFileURL
        let target = segments.reduce(root) { $0.appendingPathComponent($1) }.standardizedFileURL
        return target.path.hasPrefix(root.path + "/") ? target : nil
    }

    public static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).hexString
    }

    /// `local` 为本地文件当前内容（不存在时为 nil），`remoteETag` 为远端当前的 ETag（不知道时为 nil，视为没变）。
    public static func state(local: Data?, link: RemoteDocumentLink?, remoteETag: String?) -> RemoteDocumentState {
        guard let link, let local else { return .notDownloaded }
        let localChanged = md5(local) != link.localMD5
        let remoteChanged = remoteETag.map { $0.lowercased() != link.remoteETag } ?? false
        switch (localChanged, remoteChanged) {
        case (false, false): return .synced
        case (true, false): return .localChanges
        case (false, true): return .remoteChanges
        case (true, true): return .bothChanged
        }
    }
}
