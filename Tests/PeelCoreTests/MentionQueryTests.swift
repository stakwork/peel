import Foundation
import Testing
@testable import PeelCore

/// The `@word` a composer offers mentions for, and who matches it
/// (`MentionQuery`), shared by the Mac's composer and the iPhone's.
struct MentionQueryTests {
    private func member(_ alias: String) -> TribeMember {
        TribeMember(alias: alias, photoURL: nil, pubkey: nil, pending: false)
    }

    @Test func findsTheWordEndingAtTheCursor() {
        let text = "hi @an"
        let found = MentionQuery.word(in: text, cursor: (text as NSString).length)
        #expect(found?.query == "an")
        #expect(found?.range == NSRange(location: 3, length: 3))
        // A bare "@" asks for everyone.
        #expect(MentionQuery.word(in: "@", cursor: 1)?.query == "")
    }

    /// Only the word the cursor ends: not one further back, not one with a
    /// space after it, not an "@" inside a word, not with a selection.
    @Test func nothingWhenTheCursorIsNotAfterAnAtWord() {
        #expect(MentionQuery.word(in: "@ann hello", cursor: 10) == nil)
        #expect(MentionQuery.word(in: "@ann ", cursor: 5) == nil)
        #expect(MentionQuery.word(in: "mail@ann", cursor: 8) == nil)
        #expect(MentionQuery.word(in: "@ann", cursor: 4, selectionLength: 2) == nil)
        #expect(MentionQuery.word(in: "@ann", cursor: 9) == nil)
    }

    /// Offsets count UTF-16, as text views do: an emoji before the word
    /// moves its range by two.
    @Test func rangesAreInUTF16() {
        let text = "👋 @bo"
        let found = MentionQuery.word(in: text, cursor: (text as NSString).length)
        #expect(found?.range == NSRange(location: 3, length: 3))
        #expect(found?.query == "bo")
        // After a newline, as after a space.
        #expect(MentionQuery.word(in: "line\n@bo", cursor: 8)?.query == "bo")
    }

    /// By prefix, ignoring case, with an exact match first, so taking the
    /// first never swaps a finished alias for a longer one.
    @Test func suggestsByPrefixWithAnExactMatchFirst() {
        let members = ["Anna", "ann", "Bob", "annette"].map(member)
        #expect(MentionQuery.suggestions(members, typed: "ann").map(\.alias) == ["ann", "Anna", "annette"])
        #expect(MentionQuery.suggestions(members, typed: "B").map(\.alias) == ["Bob"])
        #expect(MentionQuery.suggestions(members, typed: "").count == 4)
        #expect(MentionQuery.suggestions(members, typed: "", limit: 2).count == 2)
        #expect(MentionQuery.suggestions(members, typed: "zed").isEmpty)
    }
}
