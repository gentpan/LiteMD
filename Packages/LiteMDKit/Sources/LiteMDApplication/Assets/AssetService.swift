import Foundation
import LiteMDDomain

public struct AssetImportResult: Equatable, Sendable {
    public var fileURL: URL
    /// 相对文档所在目录的路径，例如 `assets/image-20260917-173500.png`。
    public var markdownPath: String

    public init(fileURL: URL, markdownPath: String) {
        self.fileURL = fileURL
        self.markdownPath = markdownPath
    }
}

public struct AssetLocation: Equatable, Sendable {
    public var mode: AssetFolderMode
    public var customPath: String

    public init(mode: AssetFolderMode = .assets, customPath: String = "") {
        self.mode = mode
        self.customPath = customPath
    }

    public func directory(forDocumentAt documentURL: URL) -> URL {
        let documentDirectory = documentURL.deletingLastPathComponent()
        switch mode {
        case .sameFolder:
            return documentDirectory
        case .assets:
            return documentDirectory.appendingPathComponent("assets", isDirectory: true)
        case .images:
            return documentDirectory.appendingPathComponent("images", isDirectory: true)
        case .custom:
            let trimmed = customPath.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
            guard !trimmed.isEmpty else { return documentDirectory.appendingPathComponent("assets", isDirectory: true) }
            return documentDirectory.appendingPathComponent(trimmed, isDirectory: true).standardizedFileURL
        }
    }
}

/// 图片导入（spec §130–132）：复制到资源目录、生成不冲突的文件名、返回相对路径。
/// 绝不覆盖已存在的文件。
public final class AssetService: Sendable {
    private let fileSystem: any FileSystem

    public init(fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
    }

    /// 剪贴板图片等原始数据。
    public func importImageData(
        _ data: Data,
        fileExtension: String,
        forDocumentAt documentURL: URL,
        location: AssetLocation,
        date: Date = Date()
    ) async throws(LiteMDError) -> AssetImportResult {
        let directory = location.directory(forDocumentAt: documentURL)
        try await ensureDirectory(directory)
        let fileSystem = self.fileSystem
        let url = try await UniqueItemNaming.asset.create(in: directory, baseName: Self.timestampName(date), extension: fileExtension.lowercased()) { url throws(LiteMDError) in
            try await fileSystem.createFile(at: url, contents: data)
        }
        return AssetImportResult(fileURL: url, markdownPath: Self.relativePath(from: documentURL.deletingLastPathComponent(), to: url))
    }

    /// 导入其他格式时提取出的图片：保留转换器给出的文件名，冲突时自动追加序号。
    public func importNamedData(
        _ data: Data,
        fileName: String,
        forDocumentAt documentURL: URL,
        location: AssetLocation
    ) async throws(LiteMDError) -> AssetImportResult {
        let directory = location.directory(forDocumentAt: documentURL)
        try await ensureDirectory(directory)
        let baseName = Self.sanitizedBaseName((fileName as NSString).deletingPathExtension)
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        let fileSystem = self.fileSystem
        let url = try await UniqueItemNaming.asset.create(in: directory, baseName: baseName, extension: fileExtension) { url throws(LiteMDError) in
            try await fileSystem.createFile(at: url, contents: data)
        }
        return AssetImportResult(fileURL: url, markdownPath: Self.relativePath(from: documentURL.deletingLastPathComponent(), to: url))
    }

    /// 拖入或选择的图片文件。
    public func importFile(
        at source: URL,
        forDocumentAt documentURL: URL,
        location: AssetLocation
    ) async throws(LiteMDError) -> AssetImportResult {
        guard MarkdownFileType.isImage(source) else {
            throw LiteMDError(kind: .asset, reason: .unsupportedFileType, fileName: source.lastPathComponent)
        }
        let documentDirectory = documentURL.deletingLastPathComponent().standardizedFileURL
        let sourceURL = source.standardizedFileURL

        // 已位于文档目录树中的图片直接引用，不重复复制。
        if sourceURL.path.hasPrefix(documentDirectory.path + "/") {
            return AssetImportResult(fileURL: sourceURL, markdownPath: Self.relativePath(from: documentDirectory, to: sourceURL))
        }

        let directory = location.directory(forDocumentAt: documentURL)
        try await ensureDirectory(directory)
        let baseName = Self.sanitizedBaseName(sourceURL.deletingPathExtension().lastPathComponent)
        let fileSystem = self.fileSystem
        let url = try await UniqueItemNaming.asset.create(in: directory, baseName: baseName, extension: sourceURL.pathExtension.lowercased()) { destination throws(LiteMDError) in
            try await fileSystem.copyItem(from: sourceURL, to: destination)
        }
        return AssetImportResult(fileURL: url, markdownPath: Self.relativePath(from: documentDirectory, to: url))
    }

    private func ensureDirectory(_ directory: URL) async throws(LiteMDError) {
        if await fileSystem.isDirectory(at: directory) { return }
        var missing: [URL] = []
        var current = directory.standardizedFileURL
        while !(await fileSystem.itemExists(at: current)), current.path != "/" {
            missing.append(current)
            current = current.deletingLastPathComponent()
        }
        for url in missing.reversed() {
            do throws(LiteMDError) {
                try await fileSystem.createDirectory(at: url)
            } catch where error.reason == .alreadyExists {
                continue
            } catch {
                throw error.with(kind: .asset)
            }
        }
    }

    // MARK: Naming

    /// `image-20260917-173500`：无空格，跨平台安全（spec §131）。
    public static func timestampName(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "image-%04d%02d%02d-%02d%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }

    /// 空白替换为 `-`，去掉在 Markdown 路径或其他平台上有问题的字符。
    public static func sanitizedBaseName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "()[]<>{}#?%*:|\"'\\/`^!&;$@=+,")
        var result = ""
        var lastWasDash = false
        for scalar in name.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || forbidden.contains(scalar) {
                if !lastWasDash, !result.isEmpty {
                    result.append("-")
                    lastWasDash = true
                }
            } else {
                result.unicodeScalars.append(scalar)
                lastWasDash = scalar == "-"
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "image" : result
    }

    /// 从目录到文件的相对路径，使用 `/` 分隔。
    public static func relativePath(from directory: URL, to file: URL) -> String {
        let base = directory.standardizedFileURL.pathComponents
        let target = file.standardizedFileURL.pathComponents
        var common = 0
        while common < base.count, common < target.count, base[common] == target[common] {
            common += 1
        }
        let ups = Array(repeating: "..", count: base.count - common)
        return (ups + target[common...]).joined(separator: "/")
    }
}
