import Foundation
import LiteMDDomain

/// 面向用户的错误文案（本地化）。底层系统错误只作为“详细信息”展示（spec §160）。
extension LiteMDError {
    var localizedTitle: String {
        let name = fileName ?? String(localized: "the document")
        switch kind {
        case .file, .encoding: return String(localized: "Unable to open \(name).")
        case .save: return String(localized: "Unable to save \(name).")
        case .conflict: return String(localized: "\(name) was changed outside LiteMD.")
        case .workspace: return String(localized: "The folder operation could not be completed.")
        case .recovery: return String(localized: "Unable to recover \(name).")
        case .asset: return String(localized: "Unable to insert the image.")
        }
    }

    var localizedMessage: String {
        switch reason {
        case .notFound: String(localized: "The file or folder no longer exists. It may have been moved or deleted.")
        case .permissionDenied: String(localized: "LiteMD does not have permission to access this location.")
        case .alreadyExists: String(localized: "An item with the same name already exists.")
        case .diskFull: String(localized: "There is not enough disk space.")
        case .readOnlyVolume: String(localized: "This location is read-only.")
        case .unsupportedEncoding: String(localized: "The file is not UTF-8 or UTF-16 encoded. LiteMD did not open it to avoid damaging its contents.")
        case .isDirectory: String(localized: "This is a folder, not a file.")
        case .fileTooLarge: String(localized: "The file is too large to open in the editor.")
        case .externalModification: String(localized: "The file on disk was modified by another app. LiteMD did not overwrite it.")
        case .externalDeletion: String(localized: "The file on disk was deleted or moved.")
        case .requiresSavedDocument: String(localized: "Save the document to a file first.")
        case .invalidName: String(localized: "The name is not valid.")
        case .unsupportedFileType: String(localized: "This file type is not supported.")
        case .unknown: String(localized: "An unexpected error occurred.")
        }
    }
}
