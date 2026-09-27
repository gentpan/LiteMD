import Foundation
@testable import LiteMDDomain
import Testing

@Suite("iCloud")
struct CloudStatusTests {
    @Test func recognizesPlaceholderNames() {
        #expect(CloudLocation.placeholderName(".日记.md.icloud") == "日记.md")
        #expect(CloudLocation.placeholderName("日记.md") == nil)
        #expect(CloudLocation.placeholderName(".icloud") == nil)

        let placeholder = URL(fileURLWithPath: "/notes/.日记.md.icloud")
        #expect(CloudLocation.materializedURL(for: placeholder).lastPathComponent == "日记.md")
        let real = URL(fileURLWithPath: "/notes/日记.md")
        #expect(CloudLocation.materializedURL(for: real) == real)
        #expect(CloudLocation.placeholderURL(for: real).lastPathComponent == ".日记.md.icloud")
    }

    @Test func detectsCloudDrivePaths() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(CloudLocation.isInCloudDrive(home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Notes/a.md")))
        #expect(!CloudLocation.isInCloudDrive(URL(fileURLWithPath: "/tmp/Notes/a.md")))
    }

    @Test func statusDescribesWhenDownloadIsNeeded() {
        #expect(CloudStatus.notDownloaded.needsDownload)
        #expect(CloudStatus.downloading(fraction: 0.5).needsDownload)
        #expect(!CloudStatus.downloaded.needsDownload)
        #expect(!CloudStatus.local.needsDownload)
    }
}
