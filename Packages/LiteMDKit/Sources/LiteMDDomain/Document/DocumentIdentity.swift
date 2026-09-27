import Foundation

/// 运行中编辑会话的稳定标识。
///
/// 禁止使用 Path 作为 DocumentID：Rename、Move、Save As、Untitled 都会改变 Path。
public struct DocumentID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

/// 标准化的文件标识（设备号 + inode）。
///
/// 用于判断“同一个文件是否已经打开”，可以正确处理大小写不敏感文件系统和符号链接，
/// 也用于跟踪外部重命名。
public struct FileIdentity: Hashable, Codable, Sendable {
    public var device: UInt64
    public var inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

/// 磁盘上文件的某个版本。与 Editor Revision 完全分离。
public struct DiskRevision: Equatable, Codable, Sendable {
    /// 修改时间，纳秒精度，避免 Double 往返造成的误判。
    public var modifiedAtNanoseconds: Int64
    public var fileSize: Int64
    /// SHA-256 十六进制串。只在需要时计算。
    public var contentHash: String?

    public init(modifiedAtNanoseconds: Int64, fileSize: Int64, contentHash: String? = nil) {
        self.modifiedAtNanoseconds = modifiedAtNanoseconds
        self.fileSize = fileSize
        self.contentHash = contentHash
    }

    /// 快速判断：修改时间与大小都一致。
    public func matchesMetadata(_ other: DiskRevision) -> Bool {
        modifiedAtNanoseconds == other.modifiedAtNanoseconds && fileSize == other.fileSize
    }

    /// 内容是否一致。任一方缺少 Hash 时无法判断，返回 nil。
    public func matchesContent(_ other: DiskRevision) -> Bool? {
        guard let lhs = contentHash, let rhs = other.contentHash else { return nil }
        return lhs == rhs
    }
}

/// Document 当前绑定的外部文件。
public struct FileReference: Equatable, Codable, Sendable {
    public var url: URL
    public var encoding: TextEncoding
    public var lineEnding: LineEnding
    public var identity: FileIdentity?

    public init(
        url: URL,
        encoding: TextEncoding = .utf8,
        lineEnding: LineEnding = .lf,
        identity: FileIdentity? = nil
    ) {
        self.url = url
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.identity = identity
    }

    public var displayName: String { url.lastPathComponent }
}
