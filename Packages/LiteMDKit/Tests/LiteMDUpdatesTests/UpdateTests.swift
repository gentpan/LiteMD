import CryptoKit
import Foundation
@testable import LiteMDUpdates
import Testing

final class FakeTransport: UpdateTransport, @unchecked Sendable {
    var files: [URL: Data] = [:]

    func data(from url: URL, limit: Int64) async throws -> Data {
        guard let data = files[url] else { throw UpdateError.network("HTTP 404") }
        guard Int64(data.count) <= limit else { throw UpdateError.lengthMismatch(expected: limit, actual: Int64(data.count)) }
        return data
    }
}

@Suite("Updates")
struct UpdateTests {
    let privateKey = Curve25519.Signing.PrivateKey()
    let feedURL = URL(string: "https://updates.example.com/appcast.json")!
    let packageURL = URL(string: "https://updates.example.com/LiteMD-0.2.0.zip")!
    let macOS15 = OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 0)

    private func makeFeed(version: String = "0.2.0", package: Data, minimumSystem: String? = "15.0", signature: String? = nil) throws -> (FakeTransport, UpdateChecker) {
        let transport = FakeTransport()
        let item = UpdateItem(
            version: version,
            build: "12",
            minimumSystemVersion: minimumSystem,
            url: packageURL,
            length: Int64(package.count),
            signature: try signature ?? UpdateSignature.sign(package, privateKey: privateKey.rawRepresentation.base64EncodedString()),
            notes: ["en": "Faster.", "zh-Hans": "更快。"]
        )
        transport.files[feedURL] = try item.encoded()
        transport.files[packageURL] = package
        let checker = UpdateChecker(feedURL: feedURL, publicKey: privateKey.publicKey.rawRepresentation.base64EncodedString(), transport: transport)
        return (transport, checker)
    }

    @Test func comparesVersionsNumerically() {
        #expect(AppVersion("1.9.2") < AppVersion("1.10.0"))
        #expect(AppVersion("1.0") == AppVersion("1.0.0"))
        #expect(AppVersion("1.0.0", build: "3") < AppVersion("1.0.0", build: "4"))
        #expect(!(AppVersion("2.0") < AppVersion("1.99.99")))
    }

    @Test func reportsNewerVersionAndLocalizedNotes() async throws {
        let package = Data("new app".utf8)
        let (_, checker) = try makeFeed(package: package)
        let item = try #require(try await checker.availableUpdate(currentVersion: "0.1.0", currentBuild: "1", systemVersion: macOS15))
        #expect(item.version == "0.2.0")
        #expect(item.notes(for: ["zh-Hans-CN"]) == "更快。")
        #expect(item.notes(for: ["fr"]) == "Faster.")
        #expect(try await checker.availableUpdate(currentVersion: "0.2.0", currentBuild: "12", systemVersion: macOS15) == nil)
        #expect(try await checker.download(item) == package)
    }

    @Test func rejectsTamperedPackagesAndOldSystems() async throws {
        let package = Data("new app".utf8)
        let (transport, checker) = try makeFeed(package: package)
        let item = try #require(try await checker.availableUpdate(currentVersion: "0.1.0", currentBuild: nil, systemVersion: macOS15))

        transport.files[packageURL] = Data("evil app".utf8).prefix(package.count)
        await #expect(throws: UpdateError.invalidSignature) { try await checker.download(item) }

        transport.files[packageURL] = Data("longer evil app".utf8)
        await #expect(throws: UpdateError.lengthMismatch(expected: Int64(package.count), actual: 15)) { try await checker.download(item) }

        let (_, strict) = try makeFeed(package: package, minimumSystem: "26.0")
        await #expect(throws: UpdateError.unsupportedSystem("26.0")) {
            try await strict.availableUpdate(currentVersion: "0.1.0", currentBuild: nil, systemVersion: macOS15)
        }
    }

    @Test func rejectsSignaturesFromOtherKeys() async throws {
        let package = Data("new app".utf8)
        let other = try UpdateSignature.sign(package, privateKey: Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())
        let (_, checker) = try makeFeed(package: package, signature: other)
        let item = try #require(try await checker.availableUpdate(currentVersion: "0.1.0", currentBuild: nil, systemVersion: macOS15))
        await #expect(throws: UpdateError.invalidSignature) { try await checker.download(item) }
    }
}
