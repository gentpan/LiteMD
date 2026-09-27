import CryptoKit
import Foundation
@testable import LiteMDBackup
import LiteMDDomain
import Testing

/// AWS 文档 “Signature Calculations for the Authorization Header” 中的官方示例。
@Suite("SigV4 official vectors")
struct SigV4Tests {
    let signer = SigV4Signer(
        credentials: S3Credentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"),
        region: "us-east-1"
    )
    let date = Date(timeIntervalSince1970: 1_369_353_600) // 2013-05-24T00:00:00Z

    private func signature(_ request: URLRequest) -> String {
        request.value(forHTTPHeaderField: "Authorization")?.components(separatedBy: "Signature=").last ?? ""
    }

    @Test func getObject() {
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
        request.httpMethod = "GET"
        request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        signer.sign(&request, payloadHash: SigV4Signer.emptyPayloadHash, date: date)

        let canonical = signer.canonicalRequest(request, payloadHash: SigV4Signer.emptyPayloadHash)
        #expect(SHA256.hash(data: Data(canonical.request.utf8)).hexString == "7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972")
        #expect(canonical.signedHeaders == "host;range;x-amz-content-sha256;x-amz-date")
        #expect(signature(request) == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    @Test func putObject() {
        let body = Data("Welcome to Amazon S3.".utf8)
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test%24file.text")!)
        request.httpMethod = "PUT"
        request.setValue("Fri, 24 May 2013 00:00:00 GMT", forHTTPHeaderField: "Date")
        request.setValue("REDUCED_REDUNDANCY", forHTTPHeaderField: "x-amz-storage-class")
        let payloadHash = SHA256.hash(data: body).hexString
        #expect(payloadHash == "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")
        signer.sign(&request, payloadHash: payloadHash, date: date)
        #expect(signature(request) == "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")
    }

    @Test func getBucketLifecycle() {
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/?lifecycle")!)
        request.httpMethod = "GET"
        signer.sign(&request, payloadHash: SigV4Signer.emptyPayloadHash, date: date)
        #expect(signature(request) == "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543")
    }

    @Test func listObjects() {
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J")!)
        request.httpMethod = "GET"
        signer.sign(&request, payloadHash: SigV4Signer.emptyPayloadHash, date: date)
        #expect(signature(request) == "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")
    }

    @Test func keyEncoding() {
        #expect(SigV4Signer.encode("笔记/My Note (1).md", keepSlash: true) == "%E7%AC%94%E8%AE%B0/My%20Note%20%281%29.md")
        #expect(SigV4Signer.encode("a/b", keepSlash: false) == "a%2Fb")
    }
}

@Suite("S3 configuration")
struct S3ConfigurationTests {
    @Test func buildsVirtualHostedAndPathStyleURLs() throws {
        var configuration = S3Configuration(endpoint: "https://s3.us-west-2.amazonaws.com", region: "us-west-2", bucket: "notes", prefix: "/LiteMD/", accessKeyID: "AK")
        #expect(configuration.normalizedPrefix == "LiteMD/")
        #expect(try configuration.url(key: "LiteMD/日记.md").absoluteString == "https://notes.s3.us-west-2.amazonaws.com/LiteMD/%E6%97%A5%E8%AE%B0.md")

        configuration.endpoint = "http://127.0.0.1:9000"
        configuration.usesPathStyle = true
        #expect(try configuration.url(key: nil, query: [("list-type", "2"), ("prefix", "a b")]).absoluteString == "http://127.0.0.1:9000/notes?list-type=2&prefix=a%20b")
    }

    @Test func rejectsInsecureRemoteEndpoints() {
        let configuration = S3Configuration(endpoint: "http://example.com", region: "auto", bucket: "b", accessKeyID: "AK")
        #expect(throws: S3Error.invalidConfiguration("insecureEndpoint")) {
            try configuration.url(key: "x")
        }
    }
}

@Suite("S3 providers")
struct S3ProviderTests {
    @Test func awsDerivesRegionalEndpointAndHandlesDottedBuckets() {
        let plain = S3Provider.aws.configuration(endpoint: "ignored", region: "eu-west-1", bucket: "notes", prefix: "LiteMD", usesPathStyle: true, accessKeyID: " AK ")
        #expect(plain.endpoint == "https://s3.eu-west-1.amazonaws.com")
        #expect(plain.usesPathStyle == false)
        #expect(plain.accessKeyID == "AK")

        let dotted = S3Provider.aws.configuration(endpoint: "", region: "", bucket: "notes.example.com", prefix: "", usesPathStyle: false, accessKeyID: "AK")
        #expect(dotted.region == "us-east-1")
        #expect(dotted.usesPathStyle)
    }

    @Test func r2AndMinioUsePathStyle() {
        let r2 = S3Provider.cloudflareR2.configuration(endpoint: "https://acc.r2.cloudflarestorage.com", region: "", bucket: "b", prefix: "", usesPathStyle: false, accessKeyID: "AK")
        #expect(r2.region == "auto")
        #expect(r2.usesPathStyle)
        #expect(r2.isComplete)

        let other = S3Provider.other.configuration(endpoint: "https://cos.ap-guangzhou.myqcloud.com", region: "ap-guangzhou", bucket: "b-123", prefix: "", usesPathStyle: false, accessKeyID: "AK")
        #expect(other.usesPathStyle == false)
    }
}

// MARK: - In-memory S3

/// 内存中的 S3（路径风格）。校验签名头与 Content-MD5，可注入故障。
final class MockS3: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var objects: [String: Data] = [:]
    private var failures: [(method: String, status: Int, remaining: Int)] = []
    private(set) var requests: [String] = []
    /// 列举结果声称被截断，却不给续页令牌（只支持 V1 列举的兼容服务会这样）。
    var truncatesListingWithoutToken = false
    /// 下载时返回的内容与 ETag 不符。
    var corruptsDownloads = false

    var keys: [String] { lock.withLock { objects.keys.sorted() } }

    func object(_ key: String) -> Data? { lock.withLock { objects[key] } }

    func seed(_ key: String, _ data: Data) { lock.withLock { objects[key] = data } }

    /// 接下来 `count` 次指定方法的请求返回 `status`。
    func fail(_ method: String, status: Int, count: Int) {
        lock.withLock { failures.append((method, status, count)) }
    }

    func send(_ request: URLRequest) async throws(S3Error) -> (Data, HTTPURLResponse) {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        precondition(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256 Credential=AK/") == true)

        let injected: Int? = lock.withLock {
            requests.append(method)
            guard let index = failures.firstIndex(where: { $0.method == method && $0.remaining > 0 }) else { return nil }
            failures[index].remaining -= 1
            return failures[index].status
        }
        if let injected {
            let body = Data("<Error><Code>Injected</Code><Message>failure</Message></Error>".utf8)
            return (body, HTTPURLResponse(url: url, statusCode: injected, httpVersion: nil, headerFields: nil)!)
        }

        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)!.percentEncodedPath
        let key = String(path.dropFirst("/bucket".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")).removingPercentEncoding ?? ""

        switch method {
        case "PUT":
            let body = request.httpBody ?? Data()
            let md5 = Data(Insecure.MD5.hash(data: body)).base64EncodedString()
            precondition(request.value(forHTTPHeaderField: "Content-MD5") == md5)
            lock.withLock { objects[key] = body }
            let eTag = "\"" + Insecure.MD5.hash(data: body).hexString + "\""
            return (Data(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["ETag": eTag])!)
        case "DELETE":
            lock.withLock { objects[key] = nil }
            return (Data(), HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        default:
            let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if !key.isEmpty, !queryItems.contains(where: { $0.name == "list-type" }) {
                guard let data = lock.withLock({ objects[key] }) else {
                    return (Data("<Error><Code>NoSuchKey</Code></Error>".utf8), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
                }
                let eTag = "\"" + Insecure.MD5.hash(data: data).hexString + "\""
                let body = corruptsDownloads ? data + Data("x".utf8) : data
                return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["ETag": eTag])!)
            }
            let prefix = queryItems.first { $0.name == "prefix" }?.value ?? ""
            let delimiter = queryItems.first { $0.name == "delimiter" }?.value
            let matching = lock.withLock { objects.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key } }
            var contents = ""
            var folders: [String] = []
            for (key, data) in matching {
                let rest = key.dropFirst(prefix.count)
                if let delimiter, let range = rest.range(of: delimiter) {
                    let folder = prefix + rest[..<range.upperBound]
                    if !folders.contains(folder) { folders.append(folder) }
                    continue
                }
                contents += "<Contents><Key>\(key)</Key><ETag>&quot;\(Insecure.MD5.hash(data: data).hexString)&quot;</ETag></Contents>"
            }
            let prefixes = folders.map { "<CommonPrefixes><Prefix>\($0)</Prefix></CommonPrefixes>" }.joined()
            let truncated = truncatesListingWithoutToken ? "true" : "false"
            let xml = "<ListBucketResult><IsTruncated>\(truncated)</IsTruncated>\(contents)\(prefixes)</ListBucketResult>"
            return (Data(xml.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
}

actor MemoryManifestStore: BackupManifestStoring {
    private var manifests: [String: BackupManifest] = [:]
    func load(_ key: String) -> BackupManifest { manifests[key] ?? BackupManifest() }
    func save(_ manifest: BackupManifest, key: String) { manifests[key] = manifest }
}

final class Workspace {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("LiteMDBackup-\(UUID().uuidString)/Notes")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    func write(_ path: String, _ text: String) {
        let file = url.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: file)
    }
}

@Suite("Backup engine")
struct BackupEngineTests {
    let configuration = S3Configuration(endpoint: "http://127.0.0.1:9000", region: "us-east-1", bucket: "bucket", prefix: "LiteMD", usesPathStyle: true, accessKeyID: "AK")

    private func makeEngine(_ s3: MockS3, manifests: MemoryManifestStore) -> BackupEngine {
        BackupEngine(client: S3Client(configuration: configuration, secretAccessKey: "secret", transport: s3), manifestStore: manifests)
    }

    @Test func uploadsOnlyChangedFilesAndSkipsIgnoredOnes() async throws {
        let workspace = Workspace()
        workspace.write("README.md", "# Hello")
        workspace.write("日记/2026-09-17.md", "今天")
        workspace.write("assets/logo.png", "png-bytes")
        workspace.write(".git/config", "ignored")
        workspace.write("node_modules/x.js", "ignored")
        workspace.write(".DS_Store", "ignored")

        let s3 = MockS3()
        let manifests = MemoryManifestStore()
        let engine = makeEngine(s3, manifests: manifests)
        let folder = BackupEngine.remoteFolder(for: workspace.url, configuration: configuration)
        #expect(folder.hasPrefix("LiteMD/Notes-"))

        let first = try await engine.run(workspace: workspace.url, options: BackupOptions())
        #expect(first.uploaded == 3)
        #expect(first.failures.isEmpty)
        #expect(s3.keys == [folder + "README.md", folder + "assets/logo.png", folder + "日记/2026-09-17.md"])

        let second = try await engine.run(workspace: workspace.url, options: BackupOptions())
        #expect(second.uploaded == 0)
        #expect(second.unchanged == 3)
        #expect(s3.requests.filter { $0 == "PUT" }.count == 3)

        try await Task.sleep(for: .milliseconds(20))
        workspace.write("README.md", "# Hello again")
        let third = try await engine.run(workspace: workspace.url, options: BackupOptions())
        #expect(third.uploaded == 1)
        #expect(s3.object(folder + "README.md") == Data("# Hello again".utf8))
    }

    @Test func existingIdenticalRemoteObjectsAreNotUploadedAgain() async throws {
        let workspace = Workspace()
        workspace.write("a.md", "same")
        let s3 = MockS3()
        let folder = BackupEngine.remoteFolder(for: workspace.url, configuration: configuration)
        s3.seed(folder + "a.md", Data("same".utf8))

        let report = try await makeEngine(s3, manifests: MemoryManifestStore()).run(workspace: workspace.url, options: BackupOptions())
        #expect(report.uploaded == 0)
        #expect(report.unchanged == 1)
        #expect(!s3.requests.contains("PUT"))
    }

    @Test func remoteCopiesAreKeptUnlessMirroringIsEnabled() async throws {
        let workspace = Workspace()
        workspace.write("keep.md", "1")
        workspace.write("remove.md", "2")
        let s3 = MockS3()
        let manifests = MemoryManifestStore()
        let engine = makeEngine(s3, manifests: manifests)
        let folder = BackupEngine.remoteFolder(for: workspace.url, configuration: configuration)
        _ = try await engine.run(workspace: workspace.url, options: BackupOptions())

        try FileManager.default.removeItem(at: workspace.url.appendingPathComponent("remove.md"))
        let kept = try await engine.run(workspace: workspace.url, options: BackupOptions(mirrorDeletions: false))
        #expect(kept.deleted == 0)
        #expect(s3.keys.contains(folder + "remove.md"))

        let mirrored = try await engine.run(workspace: workspace.url, options: BackupOptions(mirrorDeletions: true))
        #expect(mirrored.deleted == 1)
        #expect(s3.keys == [folder + "keep.md"])
    }

    @Test func refusesToMirrorDeletionsWhenLocalFolderIsEmpty() async throws {
        let workspace = Workspace()
        workspace.write("note.md", "content")
        let s3 = MockS3()
        let engine = makeEngine(s3, manifests: MemoryManifestStore())
        _ = try await engine.run(workspace: workspace.url, options: BackupOptions())

        // 模拟外置磁盘未挂载：目录为空。
        try FileManager.default.removeItem(at: workspace.url.appendingPathComponent("note.md"))
        let report = try await engine.run(workspace: workspace.url, options: BackupOptions(mirrorDeletions: true))
        #expect(report.deleted == 0)
        #expect(s3.keys.count == 1)
    }

    @Test func retriesTransientErrorsAndReportsPermanentOnes() async throws {
        let workspace = Workspace()
        workspace.write("a.md", "a")
        let s3 = MockS3()
        s3.fail("PUT", status: 503, count: 2)
        let report = try await makeEngine(s3, manifests: MemoryManifestStore()).run(workspace: workspace.url, options: BackupOptions())
        #expect(report.uploaded == 1)
        #expect(report.failures.isEmpty)

        let other = Workspace()
        other.write("b.md", "b")
        let denied = MockS3()
        denied.fail("PUT", status: 403, count: 10)
        let failed = try await makeEngine(denied, manifests: MemoryManifestStore()).run(workspace: other.url, options: BackupOptions())
        #expect(failed.uploaded == 0)
        #expect(failed.failures.count == 1)
        #expect(failed.failures.first?.message.contains("403") == true)
        #expect(denied.requests.filter { $0 == "PUT" }.count == 1)
    }

    @Test func refusesToMirrorDeletionsWhenASubfolderIsUnreadable() async throws {
        let workspace = Workspace()
        workspace.write("keep.md", "1")
        workspace.write("private/secret.md", "2")
        let s3 = MockS3()
        let engine = makeEngine(s3, manifests: MemoryManifestStore())
        let folder = BackupEngine.remoteFolder(for: workspace.url, configuration: configuration)
        _ = try await engine.run(workspace: workspace.url, options: BackupOptions())

        // 子目录暂时读不了（权限、网络盘抖动）：里面的文件看起来像被删了，但不能据此删远端。
        let locked = workspace.url.appendingPathComponent("private")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let report = try await engine.run(workspace: workspace.url, options: BackupOptions(mirrorDeletions: true))
        #expect(report.deleted == 0)
        #expect(report.failures.map(\.path) == ["private"])
        #expect(s3.keys.contains(folder + "private/secret.md"))
    }

    @Test func truncatedListingWithoutContinuationTokenFails() async {
        let workspace = Workspace()
        workspace.write("a.md", "a")
        let s3 = MockS3()
        s3.truncatesListingWithoutToken = true
        await #expect(throws: S3Error.invalidResponse) {
            try await makeEngine(s3, manifests: MemoryManifestStore()).run(workspace: workspace.url, options: BackupOptions(mirrorDeletions: true))
        }
    }

    @Test func listingErrorsAbortTheRun() async {
        let workspace = Workspace()
        workspace.write("a.md", "a")
        let s3 = MockS3()
        s3.fail("GET", status: 403, count: 1)
        await #expect(throws: S3Error.http(status: 403, code: "Injected", message: "failure")) {
            try await makeEngine(s3, manifests: MemoryManifestStore()).run(workspace: workspace.url, options: BackupOptions())
        }
    }
}


@Suite("Restore engine")
struct RestoreEngineTests {
    let configuration = S3Configuration(endpoint: "http://127.0.0.1:9000", region: "us-east-1", bucket: "bucket", prefix: "LiteMD", usesPathStyle: true, accessKeyID: "AK")

    @Test func restoresBackupIntoEmptyFolderWithoutOverwriting() async throws {
        let workspace = Workspace()
        workspace.write("README.md", "# Hello")
        workspace.write("日记/一.md", "今天")
        workspace.write("assets/a.png", "png")
        let s3 = MockS3()
        let client = S3Client(configuration: configuration, secretAccessKey: "secret", transport: s3)
        _ = try await BackupEngine(client: client, manifestStore: MemoryManifestStore()).run(workspace: workspace.url, options: BackupOptions())

        let engine = RestoreEngine(client: client)
        let folders = try await engine.backupFolders()
        #expect(folders.count == 1)
        #expect(folders.first?.name == "Notes")

        let target = Workspace()
        let destination = target.url.appendingPathComponent("Restored")
        target.write("Restored/README.md", "local version")

        let report = try await engine.restore(folder: try #require(folders.first), to: destination)
        #expect(report.restored == 2)
        #expect(report.skippedExisting == 1)
        #expect(report.failures.isEmpty)
        #expect(try String(contentsOf: destination.appendingPathComponent("日记/一.md"), encoding: .utf8) == "今天")
        // 已存在的本地文件保持不变。
        #expect(try String(contentsOf: destination.appendingPathComponent("README.md"), encoding: .utf8) == "local version")
    }

    @Test func rejectsKeysThatEscapeTheDestination() async throws {
        let s3 = MockS3()
        s3.seed("LiteMD/Notes-abcdef/ok.md", Data("ok".utf8))
        s3.seed("LiteMD/Notes-abcdef/../../evil.md", Data("evil".utf8))
        s3.seed("LiteMD/Notes-abcdef/folder/", Data())
        s3.seed("LiteMD/Notes-abcdef/", Data())
        let client = S3Client(configuration: configuration, secretAccessKey: "secret", transport: s3)
        let target = Workspace()
        let destination = target.url.appendingPathComponent("Restored")

        let report = try await RestoreEngine(client: client).restore(folder: RemoteBackupFolder(prefix: "LiteMD/Notes-abcdef/", name: "Notes"), to: destination)
        #expect(report.restored == 1)
        #expect(report.failures.map(\.message) == ["Unsafe path"])
        #expect(!FileManager.default.fileExists(atPath: target.url.appendingPathComponent("evil.md").path))
        #expect(!FileManager.default.fileExists(atPath: target.url.deletingLastPathComponent().appendingPathComponent("evil.md").path))
    }

    @Test func rejectsDownloadsThatDoNotMatchTheirChecksum() async throws {
        let s3 = MockS3()
        s3.seed("LiteMD/Notes-abcdef/a.md", Data("a".utf8))
        s3.corruptsDownloads = true
        let client = S3Client(configuration: configuration, secretAccessKey: "secret", transport: s3)
        let target = Workspace()
        let destination = target.url.appendingPathComponent("Restored")

        let report = try await RestoreEngine(client: client).restore(folder: RemoteBackupFolder(prefix: "LiteMD/Notes-abcdef/", name: "Notes"), to: destination)
        #expect(report.restored == 0)
        #expect(report.failures.map(\.message) == ["Checksum mismatch"])
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("a.md").path))
    }

    @Test func displayNameStripsHashSuffixOnly() {
        #expect(RestoreEngine.displayName(forFolder: "My-Notes-1a2b3c") == "My-Notes")
        #expect(RestoreEngine.displayName(forFolder: "My-Notes") == "My-Notes")
        #expect(RestoreEngine.safeRelativePath("a/./b") == nil)
        #expect(RestoreEngine.safeRelativePath("a/b.md") == ["a", "b.md"])
    }
}
