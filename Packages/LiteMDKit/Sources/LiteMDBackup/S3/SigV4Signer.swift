import CryptoKit
import Foundation
import LiteMDDomain

/// S3 访问凭据。Secret 只在内存中使用，持久化由平台层存入钥匙串。
public struct S3Credentials: Sendable, Equatable {
    public var accessKeyID: String
    public var secretAccessKey: String

    public init(accessKeyID: String, secretAccessKey: String) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
    }
}

/// AWS Signature Version 4（S3，单块负载）。
///
/// 实现依据 AWS 文档 “Authenticating Requests: Using the Authorization Header”，
/// 并用文档中的官方示例作为测试向量。
public struct SigV4Signer: Sendable {
    public static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    public var credentials: S3Credentials
    public var region: String
    public var service = "s3"

    public init(credentials: S3Credentials, region: String) {
        self.credentials = credentials
        self.region = region
    }

    /// 对请求签名：补充 `x-amz-date`、`x-amz-content-sha256`，写入 `Authorization`。
    public func sign(_ request: inout URLRequest, payloadHash: String, date: Date) {
        let amzDate = Self.amzDate(date)
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        let parts = canonicalRequest(request, payloadHash: payloadHash)
        let scope = "\(amzDate.prefix(8))/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            SHA256.hash(data: Data(parts.request.utf8)).hexString,
        ].joined(separator: "\n")

        let signature = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: signingKey(dateStamp: String(amzDate.prefix(8)))).hexString
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope),SignedHeaders=\(parts.signedHeaders),Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    /// 规范请求（Canonical Request）与参与签名的头部列表。
    func canonicalRequest(_ request: URLRequest, payloadHash: String) -> (request: String, signedHeaders: String) {
        let url = request.url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        var headers: [String: String] = [:]
        var host = url.host() ?? ""
        if let port = url.port, !(url.scheme == "https" && port == 443) && !(url.scheme == "http" && port == 80) {
            host += ":\(port)"
        }
        headers["host"] = host
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let lowered = name.lowercased()
            guard lowered.hasPrefix("x-amz-") || ["content-type", "content-md5", "range", "date"].contains(lowered) else { continue }
            headers[lowered] = value
                .trimmingCharacters(in: .whitespaces)
                .split(separator: " ", omittingEmptySubsequences: true)
                .joined(separator: " ")
        }
        let names = headers.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(headers[$0]!)\n" }.joined()
        let signedHeaders = names.joined(separator: ";")

        let path = components?.percentEncodedPath.isEmpty == false ? components!.percentEncodedPath : "/"
        let query = Self.canonicalQuery(components?.percentEncodedQuery ?? "")

        let canonical = [
            request.httpMethod ?? "GET",
            path,
            query,
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")
        return (canonical, signedHeaders)
    }

    /// 查询参数按名称、再按值排序；无值参数写作 `name=`。
    static func canonicalQuery(_ encodedQuery: String) -> String {
        var pairs: [(name: String, value: String)] = []
        for pair in encodedQuery.split(separator: "&", omittingEmptySubsequences: true) {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(pieces[0])
            let value = pieces.count > 1 ? String(pieces[1]) : ""
            pairs.append((name, value))
        }
        pairs.sort { lhs, rhs in
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.value < rhs.value
        }
        return pairs.map { $0.name + "=" + $0.value }.joined(separator: "&")
    }

    private func signingKey(dateStamp: String) -> SymmetricKey {
        func hmac(_ key: SymmetricKey, _ value: String) -> SymmetricKey {
            SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key)))
        }
        let secret = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
        return hmac(hmac(hmac(hmac(secret, dateStamp), region), service), "aws4_request")
    }

    static func amzDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    /// S3 对象键与查询参数的 URI 编码：只保留 RFC 3986 非保留字符。
    public static func encode(_ value: String, keepSlash: Bool) -> String {
        var result = ""
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"):
                result.append(Character(UnicodeScalar(byte)))
            case UInt8(ascii: "/") where keepSlash:
                result.append("/")
            default:
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }
}
