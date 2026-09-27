import Foundation
@testable import LiteMDDomain
import Testing

@Suite("Markdown extension scanner")
struct MarkdownExtensionScannerTests {
    @Test func findsWikiLinksWithAnchorsAliasesAndEmbeds() {
        let text = "See [[Project Plan]] and [[Notes/日记#今天|today]].\n![[diagram.png]] [[#Local]]"
        let links = MarkdownExtensionScanner.wikiLinks(in: text)
        #expect(links.count == 4)
        #expect(links[0].target == "Project Plan")
        #expect(links[0].range == (text as NSString).range(of: "[[Project Plan]]"))
        #expect(links[1].target == "Notes/日记")
        #expect(links[1].anchor == "今天")
        #expect(links[1].alias == "today")
        #expect(links[1].displayText == "today")
        #expect(links[2].isEmbed)
        #expect(links[2].line == 2)
        #expect(links[2].range.location == (text as NSString).range(of: "![[").location)
        #expect(links[3].target.isEmpty)
        #expect(links[3].displayText == "Local")
    }

    @Test func ignoresCodeFrontMatterAndInvalidBrackets() {
        let text = """
        ---
        title: "[[Not a link]]"
        ---
        `[[inline code]]` and [[a [nested] link]] and [[]]

        ```
        [[in fence]] $x$
        ```
        [[Real]]
        """
        let result = MarkdownExtensionScanner.scan(text)
        #expect(result.wikiLinks.map(\.target) == ["Real"])
        #expect(result.wikiLinks.first?.line == 9)
        #expect(result.math.isEmpty)
    }

    @Test func mathFollowsPandocDelimiterRules() {
        let text = "Euler $e^{i\\pi}+1=0$ costs $5 and $10. Escaped \\$ sign and $$\\sum_i x_i$$ inline."
        let math = MarkdownExtensionScanner.scan(text).math
        #expect(math.map(\.tex) == ["e^{i\\pi}+1=0", "\\sum_i x_i"])
        #expect(math.map(\.isDisplay) == [false, true])
        #expect((text as NSString).substring(with: math[0].range) == "$e^{i\\pi}+1=0$")
    }

    @Test func multilineDisplayMath() {
        let text = "Intro\n$$\n\\begin{aligned}\na &= b \\\\\nc &= d\n\\end{aligned}\n$$\nAfter $x$"
        let math = MarkdownExtensionScanner.scan(text).math
        #expect(math.count == 2)
        #expect(math[0].isDisplay)
        #expect(math[0].line == 2)
        #expect(math[0].tex.hasPrefix("\\begin{aligned}"))
        #expect(math[0].tex.hasSuffix("\\end{aligned}"))
        #expect((text as NSString).substring(with: math[0].range).hasSuffix("$$"))
        #expect(math[1].tex == "x")
        #expect(math[1].line == 8)
    }

    @Test func inlineCodeAtLineStartIsNotAFence() {
        let result = MarkdownExtensionScanner.scan("```ls``` lists files\n\n[[Note]] and $x^2$")
        #expect(result.wikiLinks.map(\.target) == ["Note"])
        #expect(result.math.map(\.tex) == ["x^2"])
    }

    @Test func fenceClosesOnlyOnBareMarker() {
        let result = MarkdownExtensionScanner.scan("```\n```swift\n[[in code]]\n```\n[[after]]")
        #expect(result.wikiLinks.map(\.target) == ["after"])
    }

    @Test func mathAfterEscapedBackslash() {
        #expect(MarkdownExtensionScanner.scan("\\\\$x$").math.map(\.tex) == ["x"])
        #expect(MarkdownExtensionScanner.scan("\\$x$").math.isEmpty)
    }

    @Test func fenceMarkerFollowsCommonMark() {
        func fence(_ line: String) -> MarkdownFence? {
            let units = Array(line.utf16)
            return MarkdownFence.parse(units, 0, units.count)
        }
        #expect(fence("```swift") == MarkdownFence(character: 0x60, length: 3, infoIsEmpty: false))
        #expect(fence("   ~~~~ ") == MarkdownFence(character: 0x7E, length: 4, infoIsEmpty: true))
        #expect(fence("~~~ a`b")?.character == 0x7E)
        #expect(fence("    ```") == nil)
        #expect(fence("```ls```") == nil)
        #expect(fence("``") == nil)
        #expect(fence("```")?.isClosed(by: MarkdownFence(character: 0x60, length: 4, infoIsEmpty: true)) == true)
        #expect(fence("````")?.isClosed(by: MarkdownFence(character: 0x60, length: 3, infoIsEmpty: true)) == false)
    }
}
