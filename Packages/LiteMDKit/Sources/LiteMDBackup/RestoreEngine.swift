import CryptoKit
import Foundation
import LiteMDDomain

public struct RestoreReport: Sendable, Equatable {
    public var restored = 0
    public var skippedExisting = 0
    public var failures: [BackupFailure] = []

    public var succeeded: Bool { failures.isEmpty }
}

/// 远端的一份 Workspace 备份。
public struct RemoteBackupFolder: Identifiable, Hashable, Sendable {
    /// 完整前缀，例如 `LiteMD/Notes-1a2b3c/`。
    public var prefix: String
    /// 文件夹名，例如 `Notes`。
    public var name: String

    public var id: String { prefix }

    public init(prefix: String, name: String) {
        self.prefix = prefix
        self.name = name
    }
}

/// 从 S3 恢复：下载到用户选择的本地目录。
///
/// 安全规则：
/// - 绝不覆盖本地已存在的文件，已存在的文件跳过并计数；
/// - 拒绝包含 `..`、绝对路径或空路径段的对象键，远端内容无法写到目标目录之外；
/// - 下载内容与 ETag（MD5）不一致时视为失败，不写入；KMS / SSE-C 加密或分块上传的对象 ETag 不是 MD5，不做这项校验。
public struct RestoreEngine: Sendable {
    private let client: S3Client

    public init(client: S3Client) {
        self.client = client
    }

    /// 列出前缀下所有 LiteMD 备份目录（`<名称>-<6 位哈希>/`）。
    public func backupFolders() async throws(S3Error) -> [RemoteBackupFolder] {
        let base = client.configuration.normalizedPrefix
        return try await client.listFolders(prefix: base).map { prefix in
            let folder = String(prefix.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return RemoteBackupFolder(prefix: prefix, name: Self.displayName(forFolder: folder))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func displayName(forFolder folder: String) -> String {
        guard let dash = folder.lastIndex(of: "-") else { return folder }
        let suffix = folder[folder.index(after: dash)...]
        guard suffix.count == 6, suffix.allSatisfy(\.isHexDigit) else { return folder }
        return String(folder[..<dash])
    }

    public func restore(
        folder: RemoteBackupFolder,
        to destination: URL,
        maximumConcurrentDownloads: Int = 4,
        progress: @escaping @Sendable (BackupProgress) -> Void = { _ in }
    ) async throws(S3Error) -> RestoreReport {
        let objects = try await client.listObjects(prefix: folder.prefix)
        var report = RestoreReport()
        let root = destination.standardizedFileURL
        let total = objects.count
        progress(BackupProgress(completed: 0, total: total, currentPath: nil))

        let client = self.client
        var completed = 0
        await withTaskGroup(of: (String, Outcome).self) { group in
            var iterator = objects.makeIterator()
            var running = 0

            func enqueue(_ group: inout TaskGroup<(String, Outcome)>) {
                guard let object = iterator.next() else { return }
                running += 1
                let relative = String(object.key.dropFirst(folder.prefix.count))
                group.addTask {
                    (relative, await Self.download(object, relativePath: relative, root: root, client: client))
                }
            }

            for _ in 0..<max(1, maximumConcurrentDownloads) { enqueue(&group) }
            while running > 0, let (path, outcome) = await group.next() {
                running -= 1
                completed += 1
                switch outcome {
                case .restored:
                    report.restored += 1
                case .skipped:
                    report.skippedExisting += 1
                case .ignored:
                    break
                case .failed(let message):
                    report.failures.append(BackupFailure(path: path, message: message))
                }
                progress(BackupProgress(completed: completed, total: total, currentPath: path))
                if Task.isCancelled {
                    group.cancelAll()
                } else {
                    enqueue(&group)
                }
            }
        }
        return report
    }

    enum Outcome: Sendable {
        case restored
        case skipped
        /// “目录占位”对象（键以 `/` 结尾，或者就是备份目录本身）。
        case ignored
        case failed(String)
    }

    /// 校验相对路径：只允许普通路径段。
    static func safeRelativePath(_ path: String) -> [String]? {
        guard !path.isEmpty, !path.hasPrefix("/") else { return nil }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else { return nil }
        return segments
    }

    private static func download(_ object: S3Object, relativePath: String, root: URL, client: S3Client) async -> Outcome {
        guard !Task.isCancelled else { return .failed("Cancelled") }
        if relativePath.isEmpty || relativePath.hasSuffix("/") { return .ignored }
        guard let segments = safeRelativePath(relativePath) else { return .failed("Unsafe path") }

        let target = segments.reduce(root) { $0.appendingPathComponent($1) }.standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { return .failed("Unsafe path") }
        if FileManager.default.fileExists(atPath: target.path) { return .skipped }

        let data: Data
        do throws(S3Error) {
            let object = try await client.getObject(key: object.key)
            data = object.data
            if let expected = object.contentMD5, Insecure.MD5.hash(data: data).hexString != expected {
                return .failed("Checksum mismatch")
            }
        } catch {
            return .failed(BackupEngine.describe(error))
        }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // withoutOverwriting：下载期间目标被创建时同样不会覆盖。
            try data.write(to: target, options: [.withoutOverwriting])
            return .restored
        } catch CocoaError.fileWriteFileExists {
            return .skipped
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
