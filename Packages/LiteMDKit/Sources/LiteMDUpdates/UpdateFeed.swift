import CryptoKit
import Foundation

/// 更新源（JSON）：
///
/// ```json
/// {
///   "version": "0.2.0",
///   "build": "12",
///   "minimumSystemVersion": "15.0",
///   "url": "https://example.com/LiteMD-0.2.0.zip",
///   "length": 12345678,
///   "signature": "<Ed25519 签名，Base64>",
///   "notes": { "en": "…", "zh-Hans": "…" }
/// }
/// ```
///
/// 签名只覆盖安装包本身。清单里的版本号与构建号在安装前还会和包内 Info.plist 逐项核对。
public struct UpdateItem: Codable, Equatable, Sendable {
    public var version: String
    public var build: String?
    public var minimumSystemVersion: String?
    public var url: URL
    public var length: Int64
    public var signature: String
    public var notes: [String: String]?

    public init(version: String, build: String? = nil, minimumSystemVersion: String? = nil, url: URL, length: Int64, signature: String, notes: [String: String]? = nil) {
        self.version = version
        self.build = build
        self.minimumSystemVersion = minimumSystemVersion
        self.url = url
        self.length = length
        self.signature = signature
        self.notes = notes
    }

    public static func decode(_ data: Data) throws -> UpdateItem {
        try JSONDecoder().decode(UpdateItem.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// 按界面语言取更新说明：完全匹配 → 语言前缀匹配 → 英文。
    public func notes(for languages: [String]) -> String? {
        guard let notes, !notes.isEmpty else { return nil }
        for language in languages {
            if let exact = notes[language] { return exact }
            let prefix = String(language.prefix(2))
            if let match = notes.first(where: { $0.key.hasPrefix(prefix) }) { return match.value }
        }
        return notes["en"] ?? notes.values.first
    }
}

/// 版本比较：`1.10.0` > `1.9.2`；主版本相同时比较构建号。
public struct AppVersion: Comparable, Sendable {
    public var components: [Int]
    public var build: Int?

    public init(_ version: String, build: String? = nil) {
        components = version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        self.build = build.flatMap { Int($0) }
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return (lhs.build ?? 0) < (rhs.build ?? 0)
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

public enum UpdateError: Error, Equatable, Sendable {
    case invalidFeed
    case network(String)
    case lengthMismatch(expected: Int64, actual: Int64)
    case invalidSignature
    case unsupportedSystem(String)
}

/// Ed25519 签名校验。公钥随应用发布，私钥只保存在发布者本机。
public enum UpdateSignature {
    public static func verify(_ data: Data, signature: String, publicKey: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKey),
              let signatureData = Data(base64Encoded: signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
        return key.isValidSignature(signatureData, for: data)
    }

    public static func sign(_ data: Data, privateKey: String) throws -> String {
        guard let keyData = Data(base64Encoded: privateKey) else { throw UpdateError.invalidSignature }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
        return try key.signature(for: data).base64EncodedString()
    }
}

public protocol UpdateTransport: Sendable {
    /// 下载内容；超过 `limit` 字节时抛出错误，不把它读进内存。
    func data(from url: URL, limit: Int64) async throws -> Data
}

public struct URLSessionUpdateTransport: UpdateTransport {
    public init() {}

    /// 先下载到临时文件，确认大小不超过上限再读入内存：清单里的 `length` 没有签名，
    /// 不能靠它防止被塞一个超大的文件。
    public func data(from url: URL, limit: Int64) async throws -> Data {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        let (file, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.network("HTTP \(http.statusCode)")
        }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= limit else { throw UpdateError.lengthMismatch(expected: limit, actual: size) }
        return try Data(contentsOf: file)
    }
}

/// 检查与下载更新。只有签名有效、长度一致的安装包才会返回。
public struct UpdateChecker: Sendable {
    /// 更新清单与安装包的大小上限。
    static let maximumFeedSize: Int64 = 1024 * 1024
    static let maximumPackageSize: Int64 = 512 * 1024 * 1024

    public var feedURL: URL
    public var publicKey: String
    public var transport: any UpdateTransport

    public init(feedURL: URL, publicKey: String, transport: any UpdateTransport = URLSessionUpdateTransport()) {
        self.feedURL = feedURL
        self.publicKey = publicKey
        self.transport = transport
    }

    /// 有新版本时返回更新信息；已是最新时返回 nil。
    public func availableUpdate(currentVersion: String, currentBuild: String?, systemVersion: OperatingSystemVersion) async throws(UpdateError) -> UpdateItem? {
        let data: Data
        do {
            data = try await transport.data(from: feedURL, limit: Self.maximumFeedSize)
        } catch let error as UpdateError {
            throw error
        } catch {
            throw .network(error.localizedDescription)
        }
        guard let item = try? UpdateItem.decode(data) else { throw .invalidFeed }
        guard AppVersion(currentVersion, build: currentBuild) < AppVersion(item.version, build: item.build) else { return nil }
        if let minimum = item.minimumSystemVersion {
            let required = AppVersion(minimum)
            let current = AppVersion("\(systemVersion.majorVersion).\(systemVersion.minorVersion).\(systemVersion.patchVersion)")
            if current < required { throw .unsupportedSystem(minimum) }
        }
        return item
    }

    /// 下载并校验安装包。
    public func download(_ item: UpdateItem) async throws(UpdateError) -> Data {
        guard item.length > 0, item.length <= Self.maximumPackageSize else { throw .invalidFeed }
        let data: Data
        do {
            data = try await transport.data(from: item.url, limit: item.length)
        } catch let error as UpdateError {
            throw error
        } catch {
            throw .network(error.localizedDescription)
        }
        guard Int64(data.count) == item.length else {
            throw .lengthMismatch(expected: item.length, actual: Int64(data.count))
        }
        guard UpdateSignature.verify(data, signature: item.signature, publicKey: publicKey) else {
            throw .invalidSignature
        }
        return data
    }
}
