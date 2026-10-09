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
            case .namedLink: kind = "named"
            case .mention: kind = "mention"
            }
            return (kind, span.text, String(text[span.range]))
        }
    }

    /// Each piece as it shows, with what marks it: "b" bold, "i" italic,
    /// "s" struck, then a span's kind (a link's address).
    private func shown(_ text: String) -> [String] {
        MessageMarkup.inlines(text).map { inline in
            var marks: [String] = []
            if inline.emphasis.contains(.bold) { marks.append("b") }
            if inline.emphasis.contains(.italic) { marks.append("i") }
            if inline.emphasis.contains(.strikethrough) { marks.append("s") }
            switch inline.kind {
            case nil: break
            case .code: marks.append("code")
            case .link(let url): marks.append("link \(url.absoluteString)")
            case .namedLink(let url): marks.append("named \(url.absoluteString)")
            case .mention: marks.append("mention")
            }
            return marks.isEmpty ? inline.text : "\(inline.text)[\(marks.joined(separator: " "))]"
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

    @Test func emphasis() {
        #expect(shown("**b** *i* _j_ __c__ ~~s~~") == ["b[b]", " ", "i[i]", " ", "j[i]", " ", "c[b]", " ", "s[s]"])
    }

    @Test func nestedEmphasis() {
        #expect(shown("**bold *both* bold**") == ["bold [b]", "both[b i]", " bold[b]"])
        #expect(shown("***both***") == ["both[b i]"])
        #expect(shown("~~**gone**~~") == ["gone[b s]"])
    }

    @Test(arguments: ["**open", "close**", "a * b * c", "snake_case_name", "~one~", "****", "** a **"])
    func marksThatDoNotPairShowAsTyped(text: String) {
        #expect(shown(text) == [text])
    }

    @Test func marksInsideCodeAreCode() {
        #expect(shown("`**not bold**`") == ["**not bold**[code]"])
        #expect(shown("**`x`**") == ["x[b code]"])
        #expect(shown("*a `b*` c") == ["*a ", "b*[code]", " c"])
    }

    @Test func emphasisAroundALinkOrMentionIsNotTheirs() {
        #expect(shown("**https://a.co/x**") == ["https://a.co/x[b link https://a.co/x]"])
        #expect(shown("*@tom*") == ["@tom[i mention]"])
    }

    @Test func starItemsAndItalics() {
        #expect(MessageMarkup.blocks("* item\n*italic*") == [.item("item"), .paragraph("*italic*")])
        #expect(shown("*italic*") == ["italic[i]"])
    }

    @Test func namedLink() {
        #expect(shown("see [the docs](https://a.co/x) now") == ["see ", "the docs[named https://a.co/x]", " now"])
        #expect(spans("[a](https://a.co)").map(\.2) == ["[a](https://a.co)"])
    }

    @Test(arguments: [
        "[x](http://a.co)", "[x](javascript:alert)", "[x](file:///etc/passwd)", "[x](https://user@a.co)",
        "[x](sphinx.chat://?action=tribe)", "[x](a.co)",
    ])
    func namedLinksOnlyOpenHttps(text: String) {
        #expect(MessageMarkup.inlines(text).allSatisfy { $0.kind == nil })
        #expect(shown(text) == [text])
    }

    @Test func headingsQuotesAndNumbers() {
        let text = "# Title\n## Sub\n#tag\n####### seven\n> one\n>two\n\n> three\n1. first\n12) second\n3.no"
        #expect(MessageMarkup.blocks(text) == [
            .heading(1, "Title"), .heading(2, "Sub"), .paragraph("#tag\n####### seven"), .quote("one\ntwo"),
            .quote("three"), .numbered(1, "first"), .numbered(12, "second"), .paragraph("3.no"),
        ])
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

    @Test func blockMarkersInsideCodeAreCode() {
        #expect(MessageMarkup.blocks("```\n- not an item\n# nor\n> nor\n1. nor\n```") == [.code("- not an item\n# nor\n> nor\n1. nor")])
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
        ("**bold** and _it_ ~~not~~", "bold and it not"),
        ("# Title\n> quoted", "Title quoted"),
        ("1. one\n2. two", "1. one 2. two"),
        ("see [docs](https://a.co/x)", "see docs"),
        ("snake_case", "snake_case"),
        ("`**x**`", "**x**"),
    ])
    func plainText(_ text: String, _ expected: String) {
        #expect(MessageMarkup.plainText(text) == expected)
    }
}
