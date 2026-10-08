import Foundation
import Testing
@testable import PeelCore

struct MessageMarkupTests {
    /// Each span as (kind, what shows, the source text it covers).
    private func spans(_ text: String) -> [(String, String, String)] {
        MessageMarkup.spans(in: text).map { span in
            let kind: String
            switch span.kind {
            case .code: kind = "code"
            case .link: kind = "link"
            case .mention: kind = "mention"
            }
            return (kind, span.text, String(text[span.range]))
        }
    }

    private func kinds(_ text: String) -> [String] { spans(text).map(\.0) }

    @Test func inlineCodeDropsItsBackticks() {
        let text = "give the `repo-scoped concepts` from the generator"
        let found = spans(text)
        #expect(found.count == 1)
        #expect(found.first?.0 == "code")
        #expect(found.first?.1 == "repo-scoped concepts")
        #expect(found.first?.2 == "`repo-scoped concepts`")
    }

    @Test func severalSpansOnALine() {
        #expect(spans("`a` and `b`").map(\.1) == ["a", "b"])
    }

    @Test(arguments: ["a ` b", "``", "a `` b", "one `\ntwo`", "`` x ` y"])
    func unmatchedBackticksStayText(text: String) {
        #expect(kinds(text).isEmpty)
    }

    @Test func doubleAndTripleBackticksInALine() {
        #expect(spans("use ``code`` here").map(\.1) == ["code"])
        #expect(spans("use ```code``` here").map(\.1) == ["code"])
    }

    @Test func aBacktickInsideALinkStaysPartOfIt() {
        let text = "see https://example.com/a`b`c/d ok"
        #expect(kinds(text) == ["link"])
    }

    @Test func codeAfterABacktickInALinkIsStillFound() {
        let text = "see https://example.com/a`b and `c` too"
        let found = spans(text)
        #expect(found.map(\.0) == ["link", "code"])
        #expect(found.last?.1 == "c")
    }

    @Test func aLinkInsideCodeIsCode() {
        #expect(kinds("run `https://example.com/x` now") == ["code"])
    }

    @Test func aMentionInsideCodeIsCode() {
        #expect(kinds("type `@tom` to ping") == ["code"])
        #expect(kinds("@tom look at `x`") == ["mention", "code"])
    }

    @Test func onlyHttpsLinks() {
        #expect(kinds("https://example.com and http://example.com") == ["link"])
    }

    @Test func plainTextHasNoSpans() {
        #expect(kinds("nothing to see here").isEmpty)
    }

    @Test func paragraphsAndItems() {
        #expect(MessageMarkup.blocks("hi\n- one\n• two\nbye") == [
            .paragraph("hi"), .item("one"), .item("two"), .paragraph("bye"),
        ])
    }

    @Test func fencedBlockKeepsItsLinesAndDropsTheLanguage() {
        let text = "before\n```swift\nlet a = 1\n    indented\n```\nafter"
        #expect(MessageMarkup.blocks(text) == [
            .paragraph("before"), .code("let a = 1\n    indented"), .paragraph("after"),
        ])
    }

    @Test func languageNameAfterASpaceIsDropped() {
        #expect(MessageMarkup.blocks("``` python\nprint(1)\n```") == [.code("print(1)")])
    }

    @Test func windowsLineEndings() {
        #expect(MessageMarkup.blocks("```swift\r\nlet a = 1\r\n```\r\n- one") == [.code("let a = 1"), .item("one")])
    }

    @Test func fencedBlockOnOneLine() {
        #expect(MessageMarkup.blocks("```ls -la```") == [.code("ls -la")])
    }

    @Test func fencedBlockWithCodeOnTheFenceLines() {
        #expect(MessageMarkup.blocks("```let a = 1\nlet b = 2```") == [.code("let a = 1\nlet b = 2")])
    }

    @Test func unclosedFenceStaysText() {
        #expect(MessageMarkup.blocks("```\nnot closed") == [.paragraph("```\nnot closed")])
    }

    @Test func emptyFenceStaysText() {
        #expect(MessageMarkup.blocks("```\n```") == [.paragraph("```\n```")])
    }

    @Test func listMarkersInsideCodeAreCode() {
        #expect(MessageMarkup.blocks("```\n- not an item\n```") == [.code("- not an item")])
    }

    @Test func blankLinesBesideABlockAreDropped() {
        #expect(MessageMarkup.blocks("a\n\n```\nx\n```\n\nb") == [.paragraph("a"), .code("x"), .paragraph("b")])
    }

    @Test(arguments: [
        ("plain text", "plain text"),
        ("  spaced  ", "spaced"),
        ("- one item", "one item"),
        ("use `swift build` here", "use swift build here"),
        ("``a b`` and `c`", "a b and c"),
        ("```\nlet a = 1\n    let b = 2\n```", "let a = 1 let b = 2"),
        ("```swift\nx\n```", "x"),
        ("```ls -la```", "ls -la"),
        ("before\n\n```\ncode\n```\nafter", "before code after"),
        ("- one `two`\n- three", "one two three"),
        ("line one\r\nline two", "line one line two"),
        ("an unmatched ` stays", "an unmatched ` stays"),
        ("```\nnot closed", "``` not closed"),
        ("https://a.example/`x`/b", "https://a.example/`x`/b"),
        ("@ann see `x`", "@ann see x"),
        ("  \n\n  ", ""),
    ])
    func plainText(_ text: String, _ expected: String) {
        #expect(MessageMarkup.plainText(text) == expected)
    }
}
