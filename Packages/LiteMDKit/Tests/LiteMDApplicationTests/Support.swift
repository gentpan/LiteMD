import Foundation
import LiteMDApplication
import LiteMDDomain
import LiteMDInfrastructure
import LiteMDMarkdown
import Testing

final class TemporaryDirectory {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiteMDAppTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func file(_ name: String, _ contents: String? = nil) -> URL {
        let file = url.appendingPathComponent(name)
        if let contents {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(contents.utf8).write(to: file)
        }
        return file.standardizedFileURL
    }

    func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }
}

/// 可以暂停写入的文件系统，用于测试“保存期间继续输入”等竞争场景。
final class GatedFileSystem: FileSystem, @unchecked Sendable {
    private let base = LocalFileSystem()
    private let lock = NSLock()
    private var isHolding = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var _writeCount = 0
    private var _writtenTexts: [String] = []

    var writeCount: Int { lock.withLock { _writeCount } }
    var writtenTexts: [String] { lock.withLock { _writtenTexts } }

    func holdWrites() {
        lock.withLock { isHolding = true }
    }

    func releaseWrites() {
        let pending = lock.withLock {
            isHolding = false
            let pending = waiters
            waiters = []
            return pending
        }
        pending.forEach { $0.resume() }
    }

    func writeText(_ text: String, encoding: TextEncoding, lineEnding: LineEnding, to url: URL, requireExisting: Bool) async throws(LiteMDError) -> DiskRevision {
        lock.withLock {
            _writeCount += 1
            _writtenTexts.append(text)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let shouldWait = lock.withLock {
                if isHolding {
                    waiters.append(continuation)
                    return true
                }
                return false
            }
            if !shouldWait { continuation.resume() }
        }
        return try await base.writeText(text, encoding: encoding, lineEnding: lineEnding, to: url, requireExisting: requireExisting)
    }

    func readText(at url: URL) async throws(LiteMDError) -> LoadedText { try await base.readText(at: url) }
    func readData(at url: URL) async throws(LiteMDError) -> Data { try await base.readData(at: url) }
    func diskRevision(at url: URL, includeHash: Bool) async throws(LiteMDError) -> DiskRevision? { try await base.diskRevision(at: url, includeHash: includeHash) }
    func identity(at url: URL) async -> FileIdentity? { await base.identity(at: url) }
    func itemExists(at url: URL) async -> Bool { await base.itemExists(at: url) }
    func isDirectory(at url: URL) async -> Bool { await base.isDirectory(at: url) }
    func contentsOfDirectory(at url: URL, rules: WorkspaceIgnoreRules) async throws(LiteMDError) -> [WorkspaceEntry] { try await base.contentsOfDirectory(at: url, rules: rules) }
    func markdownFiles(under url: URL, rules: WorkspaceIgnoreRules) async throws(LiteMDError) -> [URL] { try await base.markdownFiles(under: url, rules: rules) }
    func createFile(at url: URL, contents: Data) async throws(LiteMDError) { try await base.createFile(at: url, contents: contents) }
    func createDirectory(at url: URL) async throws(LiteMDError) { try await base.createDirectory(at: url) }
    func moveItem(from source: URL, to destination: URL) async throws(LiteMDError) { try await base.moveItem(from: source, to: destination) }
    func copyItem(from source: URL, to destination: URL) async throws(LiteMDError) { try await base.copyItem(from: source, to: destination) }
    func trashItem(at url: URL) async throws(LiteMDError) { try await base.trashItem(at: url) }
}

@MainActor
struct TestEnvironment {
    let directory = TemporaryDirectory()
    let recoveryDirectory = TemporaryDirectory()
    let fileSystem = GatedFileSystem()
    let service: DocumentService

    init(autosave: Bool = false) {
        service = DocumentService(
            fileSystem: fileSystem,
            parser: MarkdownParser(),
            recoveryStore: FileRecoveryStore(directory: recoveryDirectory.url)
        )
        service.isAutosaveEnabled = autosave
        service.autosaveDelay = .milliseconds(20)
        service.recoveryInterval = .milliseconds(20)
    }
}

extension Document {
    /// 模拟用户在末尾输入。
    @MainActor
    func type(_ text: String) {
        applyEdit(range: NSRange(location: buffer.length, length: 0), replacement: text)
    }
}

/// 轮询等待条件成立。
@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// 模拟外部程序修改文件，确保修改时间发生变化。
func externalWrite(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url)
    let future = Date().addingTimeInterval(2)
    try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: url.path)
}
