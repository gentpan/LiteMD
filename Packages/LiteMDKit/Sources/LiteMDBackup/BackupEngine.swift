import CryptoKit
import Foundation
import LiteMDDomain

/// 单向备份：本地 Workspace → S3。
///
/// 安全规则：
/// - 只读取本地文件，绝不修改或删除本地内容；
/// - 默认不删除远端对象；开启“镜像删除”后才删除本地已不存在的远端对象；
/// - 本地一个文件都没有枚举到时（例如外置磁盘未挂载），或者有子目录读不了时，拒绝执行任何远端删除。
public struct BackupOptions: Sendable, Equatable {
    public var mirrorDeletions: Bool
    public var ignoreRules: WorkspaceIgnoreRules
    public var maximumFileSize: Int64
    public var maximumConcurrentUploads: Int

    public init(
        mirrorDeletions: Bool = false,
        ignoreRules: WorkspaceIgnoreRules = WorkspaceIgnoreRules(),
        maximumFileSize: Int64 = 512 * 1024 * 1024,
        maximumConcurrentUploads: Int = 4
    ) {
        self.mirrorDeletions = mirrorDeletions
        self.ignoreRules = ignoreRules
        self.maximumFileSize = maximumFileSize
        self.maximumConcurrentUploads = maximumConcurrentUploads
    }
}

public struct BackupProgress: Sendable, Equatable {
    public var completed: Int
    public var total: Int
    public var currentPath: String?

    public init(completed: Int, total: Int, currentPath: String?) {
        self.completed = completed
        self.total = total
        self.currentPath = currentPath
    }

    public var fraction: Double { total == 0 ? 1 : Double(completed) / Double(total) }
}

public struct BackupFailure: Codable, Sendable, Equatable {
    public var path: String
    public var message: String
}

public struct BackupReport: Codable, Sendable, Equatable {
    public var uploaded: Int = 0
    public var unchanged: Int = 0
    public var deleted: Int = 0
    public var skippedTooLarge: Int = 0
    public var failures: [BackupFailure] = []
    public var finishedAt = Date()

    public var succeeded: Bool { failures.isEmpty }
}

/// 上次备份状态：用于判断文件是否变化，避免每次都计算哈希。
public struct BackupManifest: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var size: Int64
        public var modifiedAtNanoseconds: Int64
        public var remoteETag: String
    }

    public var entries: [String: Entry] = [:]

    public init() {}
}

public protocol BackupManifestStoring: Sendable {
    func load(_ key: String) async -> BackupManifest
    func save(_ manifest: BackupManifest, key: String) async
}

/// 清单以 JSON 保存在应用数据目录，不写入用户 Workspace。
public actor FileBackupManifestStore: BackupManifestStoring {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private func url(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    public func load(_ key: String) -> BackupManifest {
        guard let data = try? Data(contentsOf: url(key)),
              let manifest = try? JSONDecoder().decode(BackupManifest.self, from: data) else { return BackupManifest() }
        return manifest
    }

    public func save(_ manifest: BackupManifest, key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: url(key), options: .atomic)
        }
    }
}

public struct BackupEngine: Sendable {
    private let client: S3Client
    private let manifestStore: any BackupManifestStoring

    public init(client: S3Client, manifestStore: any BackupManifestStoring) {
        self.client = client
        self.manifestStore = manifestStore
    }

    /// Workspace 在桶内的目录：`<前缀>/<文件夹名>-<路径哈希>/`。
    /// 加上路径哈希，避免两个同名文件夹互相覆盖备份。
    public static func remoteFolder(for workspace: URL, configuration: S3Configuration) -> String {
        let path = workspace.standardizedFileURL.path
        let hash = SHA256.hash(data: Data(path.utf8)).prefix(3).hexString
        let name = workspace.lastPathComponent.isEmpty ? "Workspace" : workspace.lastPathComponent
        return configuration.normalizedPrefix + name + "-" + hash + "/"
    }

    public func run(
        workspace: URL,
        options: BackupOptions,
        progress: @escaping @Sendable (BackupProgress) -> Void = { _ in }
    ) async throws(S3Error) -> BackupReport {
        var report = BackupReport()
        let remoteFolder = Self.remoteFolder(for: workspace, configuration: client.configuration)
        let manifestKey = Self.manifestKey(bucket: client.configuration.bucket, endpoint: client.configuration.endpoint, folder: remoteFolder)

        let (localFiles, unreadable) = Self.enumerate(workspace, options: options)
        report.failures += unreadable
        let remoteObjects = Dictionary(
            try await client.listObjects(prefix: remoteFolder).map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var manifest = await manifestStore.load(manifestKey)

        // 1. 找出需要上传的文件。
        var pending: [LocalFile] = []
        for file in localFiles {
            if file.size > options.maximumFileSize {
                report.skippedTooLarge += 1
                continue
            }
            let key = remoteFolder + file.relativePath
            let remote = remoteObjects[key]
            if let entry = manifest.entries[file.relativePath], let remote,
               entry.size == file.size, entry.modifiedAtNanoseconds == file.modifiedAtNanoseconds,
               entry.remoteETag == remote.eTag {
                report.unchanged += 1
                continue
            }
            pending.append(file)
        }

        let total = pending.count
        progress(BackupProgress(completed: 0, total: total, currentPath: nil))

        // 2. 并发上传；内容未变（MD5 与远端 ETag 相同）时只更新清单。
        let client = self.client
        var completed = 0
        await withTaskGroup(of: UploadOutcome.self) { group in
            var iterator = pending.makeIterator()
            var running = 0

            func enqueue(_ group: inout TaskGroup<UploadOutcome>) {
                guard let file = iterator.next() else { return }
                running += 1
                let key = remoteFolder + file.relativePath
                let remoteETag = remoteObjects[key]?.eTag
                group.addTask {
                    await Self.upload(file, key: key, remoteETag: remoteETag, client: client)
                }
            }

            for _ in 0..<max(1, options.maximumConcurrentUploads) { enqueue(&group) }
            while running > 0, let outcome = await group.next() {
                running -= 1
                completed += 1
                switch outcome.result {
                case .uploaded(let entry):
                    report.uploaded += 1
                    manifest.entries[outcome.file.relativePath] = entry
                case .unchanged(let entry):
                    report.unchanged += 1
                    manifest.entries[outcome.file.relativePath] = entry
                case .failed(let message):
                    report.failures.append(BackupFailure(path: outcome.file.relativePath, message: message))
                }
                progress(BackupProgress(completed: completed, total: total, currentPath: outcome.file.relativePath))
                if Task.isCancelled {
                    group.cancelAll()
                } else {
                    enqueue(&group)
                }
            }
        }

        // 3. 镜像删除（默认关闭）。有子目录读不了时，那里的文件看起来都像“本地已删除”，整轮跳过。
        let localPaths = Set(localFiles.map(\.relativePath))
        if options.mirrorDeletions, !localFiles.isEmpty, unreadable.isEmpty {
            for (key, _) in remoteObjects where key.hasPrefix(remoteFolder) {
                let relative = String(key.dropFirst(remoteFolder.count))
                guard !localPaths.contains(relative) else { continue }
                do throws(S3Error) {
                    try await client.deleteObject(key: key)
                    report.deleted += 1
                    manifest.entries[relative] = nil
                } catch {
                    report.failures.append(BackupFailure(path: relative, message: Self.describe(error)))
                }
            }
        }
        for path in manifest.entries.keys where !localPaths.contains(path) && remoteObjects[remoteFolder + path] == nil {
            manifest.entries[path] = nil
        }

        await manifestStore.save(manifest, key: manifestKey)
        report.finishedAt = Date()
        return report
    }

    // MARK: Local files

    struct LocalFile: Sendable {
        var url: URL
        var relativePath: String
        var size: Int64
        var modifiedAtNanoseconds: Int64
    }

    /// 枚举本地文件。读不了的目录或文件记为失败返回：它们不在结果里，不能被当成“本地已删除”。
    static func enumerate(_ workspace: URL, options: BackupOptions) -> (files: [LocalFile], unreadable: [BackupFailure]) {
        let root = workspace.standardizedFileURL
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        var enumeratorOptions: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !options.ignoreRules.showHiddenFiles { enumeratorOptions.insert(.skipsHiddenFiles) }

        func relativePath(of url: URL) -> String {
            String(url.standardizedFileURL.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        // 错误回调在 nextObject() 里同步调用。
        var unreadable: [BackupFailure] = []
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: enumeratorOptions, errorHandler: { url, error in
            unreadable.append(BackupFailure(path: relativePath(of: url), message: error.localizedDescription))
            return true
        }) else {
            return ([], [BackupFailure(path: "", message: "Could not read \(root.path)")])
        }

        var files: [LocalFile] = []
        while let item = enumerator.nextObject() as? URL {
            let values: URLResourceValues
            do {
                values = try item.resourceValues(forKeys: Set(keys))
            } catch {
                unreadable.append(BackupFailure(path: relativePath(of: item), message: error.localizedDescription))
                continue
            }
            if options.ignoreRules.isIgnored(name: item.lastPathComponent) {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            files.append(LocalFile(
                url: item.standardizedFileURL,
                relativePath: relativePath(of: item),
                size: Int64(values.fileSize ?? 0),
                modifiedAtNanoseconds: Int64(modified * 1_000_000_000)
            ))
        }
        return (files.sorted { $0.relativePath < $1.relativePath }, unreadable)
    }

    // MARK: Upload

    struct UploadOutcome: Sendable {
        enum Result: Sendable {
            case uploaded(BackupManifest.Entry)
            case unchanged(BackupManifest.Entry)
            case failed(String)
        }

        var file: LocalFile
        var result: Result
    }

    private static func upload(_ file: LocalFile, key: String, remoteETag: String?, client: S3Client) async -> UploadOutcome {
        guard !Task.isCancelled else { return UploadOutcome(file: file, result: .failed("Cancelled")) }
        let data: Data
        do {
            data = try Data(contentsOf: file.url, options: [.uncached])
        } catch {
            return UploadOutcome(file: file, result: .failed(error.localizedDescription))
        }
        let md5 = Insecure.MD5.hash(data: data).hexString

        if let remoteETag, remoteETag == md5 {
            let entry = BackupManifest.Entry(size: file.size, modifiedAtNanoseconds: file.modifiedAtNanoseconds, remoteETag: remoteETag)
            return UploadOutcome(file: file, result: .unchanged(entry))
        }
        do throws(S3Error) {
            let eTag = try await client.putObject(key: key, data: data, contentType: contentType(for: file.url))
            let entry = BackupManifest.Entry(size: file.size, modifiedAtNanoseconds: file.modifiedAtNanoseconds, remoteETag: eTag.isEmpty ? md5 : eTag)
            return UploadOutcome(file: file, result: .uploaded(entry))
        } catch {
            return UploadOutcome(file: file, result: .failed(describe(error)))
        }
    }

    static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd": "text/markdown; charset=utf-8"
        case "txt": "text/plain; charset=utf-8"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "webp": "image/webp"
        case "pdf": "application/pdf"
        case "json": "application/json"
        case "html", "htm": "text/html; charset=utf-8"
        default: "application/octet-stream"
        }
    }

    static func manifestKey(bucket: String, endpoint: String, folder: String) -> String {
        SHA256.hash(data: Data("\(endpoint)|\(bucket)|\(folder)".utf8)).prefix(16).hexString
    }

    public static func describe(_ error: S3Error) -> String {
        switch error {
        case .invalidConfiguration(let field): "Invalid configuration: \(field)"
        case .http(let status, let code, let message): "HTTP \(status) \(code ?? "") \(message ?? "")".trimmingCharacters(in: .whitespaces)
        case .transport(let message): message
        case .invalidResponse: "Invalid response"
        }
    }
}
