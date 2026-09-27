import Foundation
import LiteMDDomain
import Testing

@Suite("TextCodec")
struct TextCodecTests {
    @Test func decodesPlainUTF8() throws {
        let decoded = try TextCodec.decode(Data("# LiteMD\n中文\n".utf8))
        #expect(decoded.text == "# LiteMD\n中文\n")
        #expect(decoded.encoding == .utf8)
        #expect(decoded.lineEnding == .lf)
    }

    @Test func detectsUTF8BOMAndPreservesItOnSave() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("Hello\n".utf8)
        let decoded = try TextCodec.decode(data)
        #expect(decoded.text == "Hello\n")
        #expect(decoded.encoding == .utf8WithBOM)
        #expect(TextCodec.encode(decoded.text, encoding: decoded.encoding, lineEnding: decoded.lineEnding) == data)
    }

    @Test func normalizesCRLFAndRestoresItOnSave() throws {
        let data = Data("a\r\nb\r\nc".utf8)
        let decoded = try TextCodec.decode(data)
        #expect(decoded.text == "a\nb\nc")
        #expect(decoded.lineEnding == .crlf)
        #expect(TextCodec.encode(decoded.text, encoding: .utf8, lineEnding: .crlf) == data)
    }

    @Test func mixedLineEndingsUseDominantStyle() throws {
        let decoded = try TextCodec.decode(Data("a\r\nb\r\nc\nd".utf8))
        #expect(decoded.text == "a\nb\nc\nd")
        #expect(decoded.lineEnding == .crlf)
    }

    @Test func loneCarriageReturnsNeverBecomeDoubled() {
        let data = TextCodec.encode("a\r\nb\rc\n", encoding: .utf8, lineEnding: .crlf)
        #expect(String(decoding: data, as: UTF8.self) == "a\r\nb\r\nc\r\n")
    }

    @Test func roundTripsUTF16WithBOM() throws {
        for encoding in [TextEncoding.utf16LittleEndian, .utf16BigEndian] {
            let text = "LiteMD 中文 😀\n"
            let data = TextCodec.encode(text, encoding: encoding, lineEnding: .lf)
            let decoded = try TextCodec.decode(data)
            #expect(decoded.encoding == encoding)
            #expect(decoded.text == text)
        }
    }

    @Test func rejectsInvalidUTF8InsteadOfCorruptingIt() {
        #expect(throws: LiteMDError.self) {
            try TextCodec.decode(Data([0x48, 0xFF, 0xFE, 0x49, 0xC3]))
        }
    }

    @Test func selectionRangeHandlesBackwardSelection() {
        let selection = Selection(anchor: 8, head: 2)
        #expect(selection.range == NSRange(location: 2, length: 6))
        #expect(Selection(cursor: 3).range == NSRange(location: 3, length: 0))
    }

    @Test func diskRevisionComparison() {
        let base = DiskRevision(modifiedAtNanoseconds: 1_000, fileSize: 10, contentHash: "a")
        #expect(base.matchesMetadata(DiskRevision(modifiedAtNanoseconds: 1_000, fileSize: 10)))
        #expect(!base.matchesMetadata(DiskRevision(modifiedAtNanoseconds: 1_001, fileSize: 10)))
        #expect(base.matchesContent(DiskRevision(modifiedAtNanoseconds: 5, fileSize: 1, contentHash: "a")) == true)
        #expect(base.matchesContent(DiskRevision(modifiedAtNanoseconds: 5, fileSize: 1)) == nil)
    }
}
