import Testing
@testable import PeelUI

/// An agent reply read aloud (`SpokenText`).
struct SpokenTextTests {
    private func spoken(_ markdown: String) -> [String] { SpokenText(markdown: markdown).chunks }

    @Test func plainSentencesAreChunks() {
        #expect(spoken("Done. I started the job!") == ["Done.", "I started the job!"])
    }

    @Test func codeFenceIsOnePhrase() {
        let text = "Here it is:\n```swift\nlet a = 1\nlet b = 2\nlet c = 3\n```\nThat is all."
        let chunks = spoken(text)
        #expect(chunks.contains("A code block of 3 lines, skipped."))
        #expect(!chunks.joined().contains("let a"))
        #expect(chunks.last == "That is all.")
    }

    @Test func unclosedFenceIsStillSkipped() {
        #expect(spoken("```\nx\ny").joined() == "A code block of 2 lines, skipped.")
    }

    @Test func inlineCodeKeepsItsText() {
        #expect(spoken("Run `swift test` now.") == ["Run swift test now."])
    }

    @Test func linksReadAsTheirTitle() {
        #expect(spoken("See [the docs](https://example.com/docs/page) for more.") == ["See the docs for more."])
    }

    @Test func bareURLsNameTheHost() {
        #expect(spoken("Open https://github.com/stakwork/peel/pull/12.") == ["Open a link to github.com."])
        #expect(spoken("Open (https://www.example.com/x).") == ["Open (a link to example.com)."])
    }

    @Test func imagesAreAnImage() {
        #expect(spoken("![screenshot](https://x.test/a.png)") == ["an image"])
    }

    @Test func headingsEmphasisAndQuotesAreStripped() {
        let chunks = spoken("# Summary\n**Bold** and *italic* and ~~gone~~ text.\n> quoted words")
        #expect(chunks == ["Summary.", "Bold and italic and gone text.", "quoted words"])
    }

    @Test func snakeCaseKeepsItsUnderscores() {
        #expect(spoken("Call my_function_name now.") == ["Call my_function_name now."])
    }

    @Test func listsBecomeSeparateSentences() {
        let chunks = spoken("Steps:\n- first thing\n- second thing\n1. third thing\n2) fourth thing")
        #expect(chunks == ["Steps:", "first thing.", "second thing.", "third thing.", "fourth thing."])
    }

    @Test func tablesAreSkipped() {
        let chunks = spoken("Results:\n| a | b |\n|---|---|\n| 1 | 2 |\nDone.")
        #expect(chunks == ["Results:", "A table, skipped.", "Done."])
    }

    @Test func emojiAreDropped() {
        #expect(spoken("All good 🎉🚀 now ✅") == ["All good now"])
    }

    @Test func identifiersAreCollapsed() {
        #expect(spoken("Job 3f2504e0-4f89-11d3-9a0c-0305e82c3301 started.") == ["Job an identifier started."])
        #expect(spoken("Commit 9fceb02d0ae598e95dc970b74767f19372d61af8 landed.") == ["Commit an identifier landed."])
        #expect(spoken("Edit /Users/me/code/peel/App.swift please.") == ["Edit an identifier please."])
        #expect(spoken("The word abcdefabcdef stays.") == ["The word abcdefabcdef stays."])
    }

    @Test func shortRepliesAreNotShortened() {
        let text = SpokenText(markdown: "One. Two.")
        #expect(!text.isShortened)
        #expect(text.chunks == text.full)
    }

    @Test func longRepliesAreCutAtAParagraphWithANote() {
        let paragraph = (1...6).map { "This is sentence number \($0) of the paragraph." }.joined(separator: " ")
        let text = SpokenText(markdown: [paragraph, paragraph, paragraph].joined(separator: "\n\n"),
                              budget: .init(characters: 400, sentences: 20))
        #expect(text.isShortened)
        #expect(text.chunks.last == SpokenText.shortVersionNote)
        #expect(text.chunks.count == 7)
        #expect(text.full.count == 18)
    }

    @Test func aSingleLongParagraphIsCutAtASentence() {
        let paragraph = (1...30).map { "Sentence \($0) is here." }.joined(separator: " ")
        let text = SpokenText(markdown: paragraph, budget: .init(characters: 100, sentences: 20))
        #expect(text.isShortened)
        #expect(text.chunks.count > 2)
        #expect(text.chunks.dropLast().joined(separator: " ").count <= 100)
        #expect(text.full.count == 30)
    }

    @Test func sentenceLimitCutsToo() {
        let text = SpokenText(markdown: "- a\n- b\n- c\n- d", budget: .init(characters: 600, sentences: 2))
        #expect(text.chunks == ["a.", "b.", SpokenText.shortVersionNote])
    }

    @Test func emptyReplyHasNothingToSay() {
        #expect(SpokenText(markdown: "  \n").chunks.isEmpty)
        #expect(SpokenText(markdown: "---").chunks.isEmpty)
    }
}
