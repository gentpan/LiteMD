import Foundation
import LiteMDApplication
import LiteMDBackup
import LiteMDDomain
import Observation

/// S3 文档：列出桶里的 Markdown，下载到本地编辑，改完由用户决定上传覆盖还是只留在本地。
///
/// - 下载位置 `~/Documents/LiteMD/S3/<桶名>/<对象键>`，按原路径存放；
/// - 本地文件与对象的关联（下载或上传时两边的指纹）保存在 Application Support 里；
/// - 上传前检查远端在下载之后有没有被改过，被改过时先问用户，不会悄悄覆盖。
@MainActor
@Observable
final class RemoteDocumentsModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var documents: [RemoteDocument] = []
    /// 已下载文档的状态，按对象键。
    private(set) var states: [String: RemoteDocumentState] = [:]
    /// 正在下载或上传的本地文件路径。
    private(set) var busyPaths: Set<String> = []
    /// 按本地文件路径保存的关联。
    private(set) var links: [String: RemoteDocumentLink]
    /// 有未上传修改的本地文件路径。
    private(set) var pendingUploads: Set<String> = []

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let backup: BackupModel
    @ObservationIgnored private let documentService: DocumentService
    @ObservationIgnored private let linksURL: URL
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored var openDocument: (URL) async -> Void = { _ in }

    init(settings: AppSettings, backup: BackupModel, documents: DocumentService, directory: URL) {
        self.settings = settings
        self.backup = backup
        documentService = documents
        linksURL = directory.appendingPathComponent("links.json")
        links = (try? Data(contentsOf: linksURL)).flatMap { try? JSONDecoder().decode([String: RemoteDocumentLink].self, from: $0) } ?? [:]
        pendingUploads = Set(links.compactMap { path, link in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
            return RemoteDocumentStore.md5(data) == link.localMD5 ? nil : path
        })
    }

    // MARK: State

    var configuration: S3Configuration { settings.browserConfiguration() }

    var isConfigured: Bool { configuration.isComplete && backup.hasSecret }

    static var downloadsFolder: URL {
        #if DEBUG
        // 仅用于本地调试：换到不需要“文稿”文件夹访问授权的位置（屏幕锁定时没人能点授权框）。
        if let path = ProcessInfo.processInfo.environment["LITEMD_DEBUG_S3_DOWNLOADS"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/LiteMD/S3", isDirectory: true)
    }

    static func downloadsRoot(bucket: String) -> URL {
        downloadsFolder.appendingPathComponent(bucket, isDirectory: true)
    }

    func link(for url: URL?) -> RemoteDocumentLink? {
        url.flatMap { links[$0.standardizedFileURL.path] }
    }

    func hasPendingUpload(_ url: URL?) -> Bool {
        url.map { pendingUploads.contains($0.standardizedFileURL.path) } ?? false
    }

    func isBusy(_ url: URL?) -> Bool {
        url.map { busyPaths.contains($0.standardizedFileURL.path) } ?? false
    }

    // MARK: Listing

    func refresh() async {
        let configuration = configuration
        guard configuration.isComplete else {
            phase = .failed(String(localized: "Set up S3 in Settings first."))
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        phase = .loading
        let secret = await backup.loadSecret()
        guard !secret.isEmpty else {
            phase = .failed(BackupModel.message(for: .invalidConfiguration("secret")))
            return
        }
        let store = RemoteDocumentStore(client: S3Client(configuration: configuration, secretAccessKey: secret))
        do throws(S3Error) {
            let result = try await store.documents()
            guard generation == loadGeneration else { return }
            documents = result
            updateStates()
            phase = .loaded
        } catch {
            guard generation == loadGeneration else { return }
            documents = []
            states = [:]
            phase = .failed(BackupModel.message(for: error))
        }
    }

    /// 只读取已下载过的文件，未下载的不碰磁盘。
    private func updateStates() {
        let configuration = configuration
        let root = Self.downloadsRoot(bucket: configuration.bucket)
        var result: [String: RemoteDocumentState] = [:]
        for document in documents {
            guard let local = RemoteDocumentStore.localURL(for: document.key, in: root),
                  let link = matchingLink(at: local, key: document.key, configuration: configuration) else { continue }
            var state = RemoteDocumentStore.state(local: try? Data(contentsOf: local), link: link, remoteETag: document.eTag)
            if isEditedInEditor(local) { state = state.withLocalChanges }
            result[document.key] = state
        }
        states = result
    }

    // MARK: Download

    /// 下载并打开。已经下载过的按两边的状态决定直接打开、更新还是先问用户。
    func open(_ remote: RemoteDocument) async {
        let configuration = configuration
        let root = Self.downloadsRoot(bucket: configuration.bucket)
        guard let local = RemoteDocumentStore.localURL(for: remote.key, in: root) else {
            SystemIntegration.runAlert(
                title: String(localized: "“\(remote.name)” cannot be downloaded."),
                message: String(localized: "Its path in the bucket contains “..” or empty folder names."),
                buttons: [String(localized: "OK")]
            )
            return
        }
        await documentService.finishPendingSaves(under: local)
        let localData = try? Data(contentsOf: local)
        let link = matchingLink(at: local, key: remote.key, configuration: configuration)
        var state = RemoteDocumentStore.state(local: localData, link: link, remoteETag: remote.eTag)
        if isEditedInEditor(local) { state = state.withLocalChanges }

        switch state {
        case .synced, .localChanges:
            await openDocument(local)
        case .remoteChanges:
            if await download(remote, to: local, configuration: configuration) { await openDocument(local) }
        case .notDownloaded:
            guard let localData else {
                if await download(remote, to: local, configuration: configuration) { await openDocument(local) }
                return
            }
            if RemoteDocumentStore.md5(localData) == remote.eTag {
                saveLink(RemoteDocumentLink(endpoint: configuration.endpoint, bucket: configuration.bucket, key: remote.key,
                                            remoteETag: remote.eTag, localMD5: remote.eTag), for: local)
                await openDocument(local)
                return
            }
            let choice = SystemIntegration.runAlert(
                title: String(localized: "A different “\(remote.name)” is already on this Mac."),
                message: String(localized: "The file in the download folder does not match the one in S3."),
                buttons: [String(localized: "Open the Local File"), String(localized: "Download S3 Version as a Copy"), String(localized: "Cancel")],
                style: .informational
            )
            switch choice {
            case 0:
                // 记成“有未上传的修改”：上传时会用这份覆盖 S3 上的当前版本。
                saveLink(RemoteDocumentLink(endpoint: configuration.endpoint, bucket: configuration.bucket, key: remote.key,
                                            remoteETag: remote.eTag, localMD5: ""), for: local)
                await openDocument(local)
            case 1:
                await downloadCopy(of: remote.key, name: remote.name, next: local, configuration: configuration)
            default:
                break
            }
        case .bothChanged:
            let choice = SystemIntegration.runAlert(
                title: String(localized: "“\(remote.name)” was changed both here and in S3."),
                message: String(localized: "You have changes that are not uploaded, and the S3 version was updated after you downloaded it."),
                buttons: [String(localized: "Open Local Version"), String(localized: "Download S3 Version as a Copy"), String(localized: "Cancel")],
                style: .informational
            )
            switch choice {
            case 0: await openDocument(local)
            case 1: await downloadCopy(of: remote.key, name: remote.name, next: local, configuration: configuration)
            default: break
            }
        }
    }

    private func download(_ remote: RemoteDocument, to local: URL, configuration: S3Configuration) async -> Bool {
        let path = local.path
        busyPaths.insert(path)
        defer { busyPaths.remove(path) }
        guard let store = await makeStore(configuration) else { return false }
        do {
            let (data, eTag) = try await store.download(remote.key)
            try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: local, options: .atomic)
            saveLink(RemoteDocumentLink(endpoint: configuration.endpoint, bucket: configuration.bucket, key: remote.key,
                                        remoteETag: eTag, localMD5: RemoteDocumentStore.md5(data)), for: local)
            return true
        } catch let error as S3Error {
            presentFailure(String(localized: "Could not download “\(remote.name)”."), error)
            return false
        } catch {
            SystemIntegration.present(error)
            return false
        }
    }

    /// 把远端当前版本存成本地副本（`名称 (S3 2026-10-01).md`）并打开；副本不关联到 S3。
    private func downloadCopy(of key: String, name: String, next local: URL, configuration: S3Configuration) async {
        guard let store = await makeStore(configuration) else { return }
        do {
            let (data, _) = try await store.download(key)
            let copy = Self.copyURL(for: local)
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: copy, options: .withoutOverwriting)
            await openDocument(copy)
        } catch let error as S3Error {
            presentFailure(String(localized: "Could not download “\(name)”."), error)
        } catch {
            SystemIntegration.present(error)
        }
    }

    static func copyURL(for local: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let folder = local.deletingLastPathComponent()
        let base = local.deletingPathExtension().lastPathComponent + " (S3 \(formatter.string(from: Date())))"
        let ext = local.pathExtension
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(index)").appendingPathExtension(ext)
            index += 1
        }
        return candidate
    }

    // MARK: Upload

    /// 用本地版本覆盖 S3 上的文件。远端在上次下载或上传之后被改过、或已经不在时先问用户。
    func upload(_ document: Document) async {
        guard let url = document.fileReference?.url.standardizedFileURL, var link = links[url.path] else { return }
        let configuration = settings.browserConfiguration(bucket: link.bucket)
        guard configuration.endpoint == link.endpoint else {
            SystemIntegration.runAlert(
                title: String(localized: "“\(document.displayName)” came from a different S3 server."),
                message: String(localized: "Change the S3 settings back to that server to upload it."),
                buttons: [String(localized: "OK")]
            )
            return
        }
        busyPaths.insert(url.path)
        defer { busyPaths.remove(url.path) }

        if document.isDirty {
            do {
                try await documentService.save(document)
            } catch {
                SystemIntegration.present(error)
                return
            }
        }
        guard let store = await makeStore(configuration) else { return }
        let name = url.lastPathComponent
        do {
            let data = try Data(contentsOf: url)
            let current = try await store.currentETag(of: link.key)
            if current == nil {
                let choice = SystemIntegration.runAlert(
                    title: String(localized: "“\(name)” is no longer in S3."),
                    message: String(localized: "It may have been deleted or moved. Upload it again?"),
                    buttons: [String(localized: "Cancel"), String(localized: "Upload")]
                )
                guard choice == 1 else { return }
            } else if current != link.remoteETag {
                let choice = SystemIntegration.runAlert(
                    title: String(localized: "“\(name)” was changed in S3 after you downloaded it."),
                    message: String(localized: "Uploading replaces those changes with your version."),
                    buttons: [String(localized: "Cancel"), String(localized: "Download S3 Version as a Copy"), String(localized: "Upload Anyway")]
                )
                switch choice {
                case 1:
                    await downloadCopy(of: link.key, name: name, next: url, configuration: configuration)
                    return
                case 2:
                    break
                default:
                    return
                }
            }
            let eTag = try await store.upload(data, to: link.key)
            link.remoteETag = eTag
            link.localMD5 = RemoteDocumentStore.md5(data)
            link.syncedAt = Date()
            saveLink(link, for: url)
            if let index = documents.firstIndex(where: { $0.key == link.key }), link.bucket == self.configuration.bucket {
                documents[index].eTag = eTag
                documents[index].size = Int64(data.count)
                documents[index].lastModified = Date()
                updateStates()
            }
        } catch let error as S3Error {
            presentFailure(String(localized: "Could not upload “\(name)”."), error)
        } catch {
            SystemIntegration.present(error)
        }
    }

    /// 不再关联到 S3，文件留在本地。
    func unlink(_ url: URL) {
        let path = url.standardizedFileURL.path
        links[path] = nil
        pendingUploads.remove(path)
        persistLinks()
        updateStates()
    }

    /// 文件被保存或在磁盘上被修改。
    func noteLocalChange(at url: URL) {
        let path = url.standardizedFileURL.path
        guard let link = links[path] else { return }
        let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        if data.map(RemoteDocumentStore.md5) == link.localMD5 {
            pendingUploads.remove(path)
        } else {
            pendingUploads.insert(path)
        }
        updateStates()
    }

    /// 文件在应用内被重命名或移动：关联跟着走。
    func itemMoved(from oldURL: URL, to newURL: URL) {
        let oldPath = oldURL.standardizedFileURL.path
        let newPath = newURL.standardizedFileURL.path
        var changed = false
        for (path, link) in links where path == oldPath || path.hasPrefix(oldPath + "/") {
            let moved = newPath + path.dropFirst(oldPath.count)
            links[path] = nil
            links[moved] = link
            if pendingUploads.remove(path) != nil { pendingUploads.insert(moved) }
            changed = true
        }
        if changed { persistLinks() }
    }

    // MARK: Helpers

    private func matchingLink(at local: URL, key: String, configuration: S3Configuration) -> RemoteDocumentLink? {
        guard let link = links[local.path], link.key == key, link.bucket == configuration.bucket, link.endpoint == configuration.endpoint else { return nil }
        return link
    }

    private func isEditedInEditor(_ url: URL) -> Bool {
        documentService.documents.contains { $0.fileReference?.url.standardizedFileURL.path == url.path && $0.isDirty }
    }

    private func saveLink(_ link: RemoteDocumentLink, for local: URL) {
        let path = local.standardizedFileURL.path
        links[path] = link
        noteLocalChange(at: local)
        persistLinks()
    }

    private func persistLinks() {
        let url = linksURL
        guard let data = try? JSONEncoder().encode(links) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func makeStore(_ configuration: S3Configuration) async -> RemoteDocumentStore? {
        let secret = await backup.loadSecret()
        guard !secret.isEmpty else {
            presentFailure(String(localized: "S3 is not set up."), .invalidConfiguration("secret"))
            return nil
        }
        return RemoteDocumentStore(client: S3Client(configuration: configuration, secretAccessKey: secret))
    }

    private func presentFailure(_ title: String, _ error: S3Error) {
        SystemIntegration.runAlert(
            title: title,
            message: BackupModel.message(for: error),
            buttons: [String(localized: "OK")],
            details: BackupEngine.describe(error)
        )
    }
}

private extension RemoteDocumentState {
    /// 编辑器里还有没保存的修改，同样算本地有修改。
    var withLocalChanges: RemoteDocumentState {
        switch self {
        case .synced: .localChanges
        case .remoteChanges: .bothChanged
        default: self
        }
    }
}
