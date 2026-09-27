import Foundation

/// 文件在 iCloud Drive 中的状态。普通本地文件为 `.local`。
public enum CloudStatus: Hashable, Sendable {
    /// 不在 iCloud 中。
    case local
    /// 在 iCloud 中且本地已有完整内容。
    case downloaded
    /// 正在下载（0…1，未知时为 nil）。
    case downloading(fraction: Double?)
    /// 只有占位符，本地没有内容。
    case notDownloaded
    /// 本地有改动尚未上传完成。
    case uploading

    /// 需要先下载才能打开。
    public var needsDownload: Bool {
        switch self {
        case .notDownloaded, .downloading: true
        default: false
        }
    }
}

/// iCloud Drive 的位置与占位符文件名处理。
public enum CloudLocation {
    /// `~/Library/Mobile Documents/com~apple~CloudDocs`
    public static var iCloudDriveURL: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public static func isInCloudDrive(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.contains("/Library/Mobile Documents/")
    }

    /// 未下载的文件在磁盘上可能是 `.笔记.md.icloud` 占位符，还原为真实文件名。
    public static func placeholderName(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return nil }
        let inner = name.dropFirst().dropLast(".icloud".count)
        return inner.isEmpty ? nil : String(inner)
    }

    /// 占位符对应的真实文件地址。
    public static func materializedURL(for url: URL) -> URL {
        guard let name = placeholderName(url.lastPathComponent) else { return url }
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// 真实文件对应的占位符地址（文件尚未下载时磁盘上存在的那个）。
    public static func placeholderURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
    }
}
