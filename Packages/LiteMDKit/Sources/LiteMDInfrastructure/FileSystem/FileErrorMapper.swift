import Darwin
import Foundation
import LiteMDDomain

/// 把系统错误翻译为 `LiteMDError`。原始错误只保留在 `technicalDetails` 中（spec §160）。
enum FileErrorMapper {
    static func map(_ error: any Error, fileName: String?, kind: LiteMDError.Kind = .file) -> LiteMDError {
        let nsError = error as NSError
        var reason = LiteMDError.Reason.unknown

        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                reason = .notFound
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                reason = .permissionDenied
            case NSFileWriteOutOfSpaceError:
                reason = .diskFull
            case NSFileWriteVolumeReadOnlyError:
                reason = .readOnlyVolume
            case NSFileWriteFileExistsError:
                reason = .alreadyExists
            case NSFileReadInapplicableStringEncodingError, NSFileReadUnknownStringEncodingError:
                reason = .unsupportedEncoding
            case NSFileReadTooLargeError:
                reason = .fileTooLarge
            default:
                if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
                    reason = posixReason(Int32(underlying.code))
                }
            }
        } else if nsError.domain == NSPOSIXErrorDomain {
            reason = posixReason(Int32(nsError.code))
        }

        return LiteMDError(
            kind: kind,
            reason: reason,
            fileName: fileName,
            technicalDetails: "\(nsError.domain) Code \(nsError.code): \(nsError.localizedDescription)"
        )
    }

    static func posix(_ code: Int32, fileName: String?, kind: LiteMDError.Kind = .file, operation: String) -> LiteMDError {
        LiteMDError(
            kind: kind,
            reason: posixReason(code),
            fileName: fileName,
            technicalDetails: "\(operation): POSIX \(code) \(String(cString: strerror(code)))"
        )
    }

    static func posixReason(_ code: Int32) -> LiteMDError.Reason {
        switch code {
        case ENOENT, ENOTDIR: .notFound
        case EACCES, EPERM: .permissionDenied
        case ENOSPC, EDQUOT: .diskFull
        case EROFS: .readOnlyVolume
        case EEXIST, ENOTEMPTY: .alreadyExists
        case EISDIR: .isDirectory
        case EFBIG: .fileTooLarge
        case ENAMETOOLONG, EINVAL: .invalidName
        default: .unknown
        }
    }
}
