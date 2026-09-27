import CryptoKit
import Darwin
import Foundation
import LiteMDDomain

/// 基于 POSIX / Foundation 的本地文件系统实现。所有方法都在后台执行，不阻塞主线程。
public final class LocalFileSystem: FileSystem {
    /// 超过该大小的文件不在编辑器中打开。
    public static let maximumEditableFileSize: Int64 = 64 * 1024 * 1024

    public init() {}

    // MARK: Read

    @concurrent
    public func readText(at url: URL) async throws(LiteMDError) -> LoadedText {
        try Self.readText(url)
    }

    // MARK: iCloud

    @concurrent
    public func cloudStatus(at url: URL) async -> CloudStatus {
        Self.cloudStatus(url)
    }

    /// 让 iCloud 把文件下载到本地。已下载或非 iCloud 文件立即返回；超时按“下载中”报错。
    @concurrent
    public func ensureDownloaded(at url: URL) async throws(LiteMDError) {
        let name = url.lastPathComponent
        guard Self.cloudStatus(url).needsDownload else { return }
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            throw FileErrorMapper.map(error, fileName: name)
        }
        // 轮询等待，最长 60 秒。
        for _ in 0..<600 {
            if Task.isCancelled { return }
            switch Self.cloudStatus(url) {
            case .downloaded, .local, .uploading:
                return
            case .downloading, .notDownloaded:
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        throw LiteMDError(kind: .file, reason: .unknown, fileName: name, technicalDetails: "iCloud download timed out")
    }

    @concurrent
    public func cloudConflicts(at url: URL) async -> [VersionSnapshot] {
        (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).map { version in
            let size = (try? version.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return VersionSnapshot(
                originalURL: url,
                fileURL: version.url,
                date: version.modificationDate ?? .distantPast,
                byteCount: Int64(size),
                origin: .cloudConflict,
                deviceName: version.localizedNameOfSavingComputer
            )
        }
        .sorted { $0.date > $1.date }
    }

    @concurrent
    public func resolveCloudConflicts(at url: URL) async {
        for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
            version.isResolved = true
        }
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
    }

    static func cloudStatus(_ url: URL) -> CloudStatus {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemIsUploadingKey,
        ]
        if let values = try? url.resourceValues(forKeys: keys), values.isUbiquitousItem == true {
            return cloudStatus(values)
        }
        // 只有占位符时，真实路径可能还不存在。
        let placeholder = CloudLocation.placeholderURL(for: url)
        if FileManager.default.fileExists(atPath: placeholder.path) { return .notDownloaded }
        return .local
    }

    static func cloudStatus(_ values: URLResourceValues?) -> CloudStatus {
        guard let values, values.isUbiquitousItem == true else { return .local }
        if values.ubiquitousItemIsDownloading == true {
            // 进度只能通过 NSMetadataQuery 取得，这里只表示“正在下载”。
            return .downloading(fraction: nil)
        }
        switch values.ubiquitousItemDownloadingStatus {
        case .current:
            return values.ubiquitousItemIsUploading == true ? .uploading : .downloaded
        case .downloaded:
            return .downloaded
        default:
            return .notDownloaded
        }
    }

    @concurrent
    public func readData(at url: URL) async throws(LiteMDError) -> Data {
        do {
            return try Data(contentsOf: url, options: [.uncached])
        } catch {
            throw FileErrorMapper.map(error, fileName: url.lastPathComponent)
        }
    }

    static func readText(_ url: URL) throws(LiteMDError) -> LoadedText {
        let name = url.lastPathComponent

        // 读取前后元数据必须一致，否则说明读取期间文件被改写，重试。
        // 否则可能把新版本的元数据和旧版本的内容配对，导致之后静默覆盖外部修改。
        for _ in 0..<3 {
            guard let before = try FileStat.load(url, fileName: name) else {
                throw LiteMDError(kind: .file, reason: .notFound, fileName: name)
            }
            guard !before.isDirectory else {
                throw LiteMDError(kind: .file, reason: .isDirectory, fileName: name)
            }
            guard before.size <= maximumEditableFileSize else {
                throw LiteMDError(kind: .file, reason: .fileTooLarge, fileName: name)
            }

            let data: Data
            do {
                data = try Data(contentsOf: url, options: [.uncached])
            } catch {
                throw FileErrorMapper.map(error, fileName: name)
            }

            guard let after = try FileStat.load(url, fileName: name), after.matches(before), after.size == Int64(data.count) else {
                continue
            }

            let decoded: DecodedText
            do {
                decoded = try TextCodec.decode(data)
            } catch {
                throw error.with(fileName: name)
            }

            return LoadedText(
                text: decoded.text,
                encoding: decoded.encoding,
                lineEnding: decoded.lineEnding,
                diskRevision: DiskRevision(
                    modifiedAtNanoseconds: after.modifiedAtNanoseconds,
                    fileSize: after.size,
                    contentHash: sha256(data)
                ),
                identity: after.identity
            )
        }
        throw LiteMDError(kind: .file, reason: .unknown, fileName: name, technicalDetails: "The file kept changing while it was being read.")
    }

    // MARK: Write

    @concurrent
    public func writeText(_ text: String, encoding: TextEncoding, lineEnding: LineEnding, to url: URL, requireExisting: Bool) async throws(LiteMDError) -> DiskRevision {
        let data = TextCodec.encode(text, encoding: encoding, lineEnding: lineEnding)
        // iCloud 中的文件通过文件协调写入，避免与同步守护进程互相覆盖。
        guard CloudLocation.isInCloudDrive(url) else {
            return try Self.writeAtomically(data, to: url, requireExisting: requireExisting)
        }
        return try Self.coordinatedWrite(data, to: url, requireExisting: requireExisting)
    }

    /// NSFileCoordinator 写入；协调失败时退回直接写入，不阻断保存。
    static func coordinatedWrite(_ data: Data, to url: URL, requireExisting: Bool) throws(LiteMDError) -> DiskRevision {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<DiskRevision, LiteMDError>?
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do throws(LiteMDError) {
                result = .success(try writeAtomically(data, to: coordinatedURL, requireExisting: requireExisting))
            } catch {
                result = .failure(error)
            }
        }
        if let result {
            return try result.get()
        }
        return try writeAtomically(data, to: url, requireExisting: requireExisting)
    }

    /// document.md → temporary → flush → fsync → atomic replace（spec §81）。
    static func writeAtomically(_ data: Data, to url: URL, requireExisting: Bool = false) throws(LiteMDError) -> DiskRevision {
        let name = url.lastPathComponent
        let target = url.resolvingSymlinksInPath()
        let directory = target.deletingLastPathComponent()
        let deleted = LiteMDError(kind: .conflict, reason: .externalDeletion, fileName: name)

        let existing = try FileStat.load(target, fileName: name)
        if let existing, existing.isDirectory {
            throw LiteMDError(kind: .save, reason: .isDirectory, fileName: name)
        }
        if existing == nil, requireExisting {
            throw deleted
        }
        let permissions = existing.map { $0.mode & 0o7777 } ?? 0o644

        let temporaryName = ".\(target.lastPathComponent).litemd-\(UUID().uuidString.prefix(8)).tmp"
        let temporaryURL = directory.appendingPathComponent(temporaryName)

        let descriptor = temporaryURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
        }
        guard descriptor >= 0 else {
            throw FileErrorMapper.posix(errno, fileName: name, kind: .save, operation: "open temporary")
        }

        var temporaryExists = true
        defer {
            if temporaryExists {
                temporaryURL.withUnsafeFileSystemRepresentation { path in
                    if let path { _ = unlink(path) }
                }
            }
        }

        do throws(LiteMDError) {
            try writeAll(descriptor, data, fileName: name)
            // F_FULLFSYNC 让数据真正落到存储介质；不支持时退回 fsync。
            if fcntl(descriptor, F_FULLFSYNC) == -1, fsync(descriptor) != 0 {
                throw FileErrorMapper.posix(errno, fileName: name, kind: .save, operation: "fsync")
            }
            _ = fchmod(descriptor, permissions)
        } catch {
            close(descriptor)
            throw error
        }
        guard close(descriptor) == 0 else {
            throw FileErrorMapper.posix(errno, fileName: name, kind: .save, operation: "close")
        }

        if existing != nil {
            // 写临时文件期间原文件可能被移走或删除，而 replaceItemAt 会在原位置重新创建它。
            if requireExisting, try FileStat.load(target, fileName: name) == nil {
                throw deleted
            }
            do {
                // 保留原文件的权限、扩展属性与创建时间。
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temporaryURL, backupItemName: nil, options: [])
            } catch {
                throw FileErrorMapper.map(error, fileName: name, kind: .save)
            }
        } else {
            let result = temporaryURL.withUnsafeFileSystemRepresentation { source in
                target.withUnsafeFileSystemRepresentation { destination in
                    renamex_np(source, destination, UInt32(RENAME_EXCL))
                }
            }
            guard result == 0 else {
                throw FileErrorMapper.posix(errno, fileName: name, kind: .save, operation: "rename")
            }
        }
        temporaryExists = false
        syncDirectory(directory)

        guard let written = try FileStat.load(target, fileName: name) else {
            throw LiteMDError(kind: .save, reason: .notFound, fileName: name)
        }
        return DiskRevision(
            modifiedAtNanoseconds: written.modifiedAtNanoseconds,
            fileSize: written.size,
            contentHash: sha256(data)
        )
    }

    private static func writeAll(_ descriptor: Int32, _ data: Data, fileName: String) throws(LiteMDError) {
        guard !data.isEmpty else { return }
        var failure: Int32?
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += written
            }
        }
        if let failure {
            throw FileErrorMapper.posix(failure, fileName: fileName, kind: .save, operation: "write")
        }
    }

    private static func syncDirectory(_ directory: URL) {
        directory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            let descriptor = open(path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { return }
            _ = fsync(descriptor)
            close(descriptor)
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).hexString
    }

    // MARK: Metadata

    @concurrent
    public func diskRevision(at url: URL, includeHash: Bool) async throws(LiteMDError) -> DiskRevision? {
        let name = url.lastPathComponent
        guard let info = try FileStat.load(url, fileName: name) else { return nil }
        var revision = DiskRevision(modifiedAtNanoseconds: info.modifiedAtNanoseconds, fileSize: info.size)
        if includeHash, !info.isDirectory {
            do {
                revision.contentHash = Self.sha256(try Data(contentsOf: url, options: [.uncached]))
            } catch {
                throw FileErrorMapper.map(error, fileName: name)
            }
        }
        return revision
    }

    @concurrent
    public func identity(at url: URL) async -> FileIdentity? {
        (try? FileStat.load(url, fileName: nil))??.identity
    }

    @concurrent
    public func itemExists(at url: URL) async -> Bool {
        (try? FileStat.load(url, fileName: nil)) != nil
    }

    @concurrent
    public func isDirectory(at url: URL) async -> Bool {
        (try? FileStat.load(url, fileName: nil))??.isDirectory ?? false
    }

    // MARK: Directory

    @concurrent
    public func contentsOfDirectory(at url: URL, rules: WorkspaceIgnoreRules) async throws(LiteMDError) -> [WorkspaceEntry] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemIsUploadingKey,
        ]
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
        } catch {
            throw FileErrorMapper.map(error, fileName: url.lastPathComponent, kind: .workspace)
        }

        var entries: [WorkspaceEntry] = []
        entries.reserveCapacity(children.count)
        for child in children {
            if Task.isCancelled { break }
            // 未下载的 iCloud 文件在磁盘上可能是 `.名称.icloud` 占位符，按真实文件名显示。
            let name = CloudLocation.placeholderName(child.lastPathComponent) ?? child.lastPathComponent
            let child = CloudLocation.materializedURL(for: child)
            guard !rules.isIgnored(name: name) else { continue }
            let values = try? child.resourceValues(forKeys: Set(keys))
            var isDirectory = values?.isDirectory ?? false
            if values?.isSymbolicLink == true {
                let resolved = child.resolvingSymlinksInPath()
                isDirectory = (try? resolved.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            }
            if values?.isPackage == true { isDirectory = false }
            entries.append(WorkspaceEntry(
                url: child.standardizedFileURL,
                kind: isDirectory ? .directory : .file,
                cloudStatus: Self.cloudStatus(values)
            ))
        }

        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return entries
    }

    @concurrent
    public func markdownFiles(under url: URL, rules: WorkspaceIgnoreRules) async throws(LiteMDError) -> [URL] {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !rules.showHiddenFiles { options.insert(.skipsHiddenFiles) }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: options) else {
            throw LiteMDError(kind: .workspace, reason: .notFound, fileName: url.lastPathComponent)
        }

        var result: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if rules.isIgnored(name: item.lastPathComponent) {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }
            if !isDirectory, MarkdownFileType.isDocument(item) {
                // 枚举器返回真实路径（例如 /private/tmp/…），而应用内统一使用标准化路径（/tmp/…）。
                result.append(item.standardizedFileURL)
            }
        }
        return result
    }

    // MARK: Mutations

    @concurrent
    public func createFile(at url: URL, contents: Data) async throws(LiteMDError) {
        let name = url.lastPathComponent
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        }
        guard descriptor >= 0 else {
            throw FileErrorMapper.posix(errno, fileName: name, operation: "create")
        }
        do throws(LiteMDError) {
            try Self.writeAll(descriptor, contents, fileName: name)
            _ = fsync(descriptor)
        } catch {
            close(descriptor)
            url.withUnsafeFileSystemRepresentation { path in
                if let path { _ = unlink(path) }
            }
            throw error
        }
        close(descriptor)
    }

    @concurrent
    public func createDirectory(at url: URL) async throws(LiteMDError) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            throw FileErrorMapper.map(error, fileName: url.lastPathComponent)
        }
    }

    @concurrent
    public func moveItem(from source: URL, to destination: URL) async throws(LiteMDError) {
        let name = source.lastPathComponent
        // 不跟随符号链接：a.md 是指向 b.md 的链接时，跟随后两者是同一个文件，
        // 会被误判为大小写重命名，用链接覆盖掉真正的 b.md。
        let sourceStat = try FileStat.load(source, fileName: name, followingSymlinks: false)
        guard let sourceStat else {
            throw LiteMDError(kind: .file, reason: .notFound, fileName: name)
        }
        let destinationStat = try FileStat.load(destination, fileName: destination.lastPathComponent, followingSymlinks: false)

        let result: Int32
        if let destinationStat {
            // 仅大小写不同的重命名（大小写不敏感的卷上两者是同一个文件）。
            guard destinationStat.identity == sourceStat.identity else {
                throw LiteMDError(kind: .file, reason: .alreadyExists, fileName: destination.lastPathComponent)
            }
            result = source.withUnsafeFileSystemRepresentation { from in
                destination.withUnsafeFileSystemRepresentation { to in rename(from, to) }
            }
        } else {
            result = source.withUnsafeFileSystemRepresentation { from in
                destination.withUnsafeFileSystemRepresentation { to in renamex_np(from, to, UInt32(RENAME_EXCL)) }
            }
        }

        if result == 0 { return }
        let code = errno
        guard code == EXDEV else {
            throw FileErrorMapper.posix(code, fileName: name, operation: "move")
        }
        // 跨卷移动。
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw FileErrorMapper.map(error, fileName: name)
        }
    }

    @concurrent
    public func copyItem(from source: URL, to destination: URL) async throws(LiteMDError) {
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw FileErrorMapper.map(error, fileName: source.lastPathComponent)
        }
    }

    @concurrent
    public func trashItem(at url: URL) async throws(LiteMDError) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            throw FileErrorMapper.map(error, fileName: url.lastPathComponent)
        }
    }
}

struct FileStat {
    var mode: mode_t
    var size: Int64
    var modifiedAtNanoseconds: Int64
    var identity: FileIdentity

    var isDirectory: Bool { mode & S_IFMT == S_IFDIR }

    func matches(_ other: FileStat) -> Bool {
        size == other.size && modifiedAtNanoseconds == other.modifiedAtNanoseconds && identity == other.identity
    }

    /// 文件不存在时返回 nil。默认跟随符号链接；`followingSymlinks` 为 false 时描述链接本身。
    static func load(_ url: URL, fileName: String?, followingSymlinks: Bool = true) throws(LiteMDError) -> FileStat? {
        var info = stat()
        var failure: Int32 = 0
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            let value = followingSymlinks ? stat(path, &info) : lstat(path, &info)
            if value != 0 { failure = errno }
            return value
        }
        guard result == 0 else {
            if failure == ENOENT || failure == ENOTDIR { return nil }
            throw FileErrorMapper.posix(failure, fileName: fileName, operation: "stat")
        }
        let nanoseconds = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return FileStat(
            mode: info.st_mode,
            size: Int64(info.st_size),
            modifiedAtNanoseconds: nanoseconds,
            identity: FileIdentity(device: UInt64(bitPattern: Int64(info.st_dev)), inode: info.st_ino)
        )
    }
}
