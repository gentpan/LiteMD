import Foundation

/// 统一错误类型（spec §159）。
///
/// 底层系统错误（例如 `NSCocoaErrorDomain Code 513`）只放在 `technicalDetails`，
/// 不直接展示给普通用户。
public struct LiteMDError: Error, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case file
        case encoding
        case save
        case conflict
        case workspace
        case recovery
        case asset
    }

    public enum Reason: String, Sendable {
        case notFound
        case permissionDenied
        case alreadyExists
        /// 目标文件已在另一个标签页中打开。
        case alreadyOpen
        case diskFull
        case readOnlyVolume
        case unsupportedEncoding
        case isDirectory
        case fileTooLarge
        case externalModification
        case externalDeletion
        case requiresSavedDocument
        case invalidName
        case unsupportedFileType
        case unknown
    }

    public var kind: Kind
    public var reason: Reason
    public var fileName: String?
    public var technicalDetails: String?

    public init(kind: Kind, reason: Reason, fileName: String? = nil, technicalDetails: String? = nil) {
        self.kind = kind
        self.reason = reason
        self.fileName = fileName
        self.technicalDetails = technicalDetails
    }

    public func with(kind: Kind? = nil, fileName: String? = nil) -> LiteMDError {
        var copy = self
        if let kind { copy.kind = kind }
        if let fileName { copy.fileName = fileName }
        return copy
    }
}
