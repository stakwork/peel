import Foundation
import Testing
@testable import PeelUI

/// The user's lingo in voice mode: contextual strings and the rewrite.
struct VoiceVocabularyTests {
    private func entry(
        _ name: String, _ heard: [(String?, String)] = [], off: Bool = false
    ) -> LingoLexicon.Entry {
        LingoLexicon.Entry(
            refID: name, type: "Term", name: name,
            heard: heard.enumerated().map { LingoLexicon.Heard(refID: "\(name)\($0.offset)", value: $0.element.1, form: $0.element.0) },
            dictationOff: off
        )
    }

    private func lexicon(_ entries: LingoLexicon.Entry...) -> LingoLexicon { LingoLexicon(entries: entries) }

    private func rewrite(_ text: String, _ lexicon: LingoLexicon?) -> String {
        LexiconRewriter.apply(text, lexicon: lexicon)
    }

    // MARK: contextualStrings

    @Test func baseComesFirstThenTheUsersTerms() {
        let lex = lexicon(entry("Kubernetes", [("cooper nettys", "Kubernetes")]), entry("Stakwork"))
        let strings = VoiceVocabulary.contextualStrings(from: lex, base: ["Peel", "peel send"])
        #expect(strings == ["Peel", "peel send", "Kubernetes", "Stakwork"])
    }

    @Test func termsWithMishearingsComeBeforeBareNames() {
        let lex = lexicon(entry("Bare"), entry("Strut", [("stroot", "Strut")]))
        #expect(VoiceVocabulary.contextualStrings(from: lex, base: []) == ["Strut", "Bare"])
    }

    @Test func repeatsAreDroppedWhateverTheCase() {
        let lex = lexicon(entry("Peel", [("pill", "peel")]), entry("PEEL send"))
        let strings = VoiceVocabulary.contextualStrings(from: lex, base: ["Peel", "peel send"])
        #expect(strings == ["Peel", "peel send"])
    }

    @Test func entriesLeftAloneAreNotUsed() {
        let lex = lexicon(entry("Off", [("of", "Off")], off: true), entry("On"))
        #expect(VoiceVocabulary.contextualStrings(from: lex, base: []) == ["On"])
    }

    @Test func theLimitCapsTheList() {
        let lex = lexicon(entry("A"), entry("B"), entry("C"))
        #expect(VoiceVocabulary.contextualStrings(from: lex, base: ["Peel"], limit: 3) == ["Peel", "A", "B"])
        #expect(VoiceVocabulary.contextualStrings(from: lex, base: ["x", "y", "z"], limit: 2) == ["x", "y"])
    }

    @Test func noLexiconIsJustTheBase() {
        #expect(VoiceVocabulary.contextualStrings(from: nil, base: ["Peel", " ", "Peel"]) == ["Peel"])
    }

    // MARK: LexiconRewriter

    @Test func aMishearingBecomesTheWrittenValue() {
        let lex = lexicon(entry("Kubernetes", [("cooper nettys", "Kubernetes")]))
        #expect(rewrite("deploy it to cooper nettys now", lex) == "deploy it to Kubernetes now")
    }

    @Test func aFormlessHeardUsesTheEntitysName() {
        let lex = lexicon(entry("pearl", [(nil, "Perl")]))
        #expect(rewrite("write it in pearl", lex) == "write it in Perl")
    }

    @Test func caseOfTheHeardWordDoesNotMatter() {
        let lex = lexicon(entry("Strut", [("stroot", "Strut")]))
        #expect(rewrite("Stroot and STROOT and stroot", lex) == "Strut and Strut and Strut")
    }

    @Test func onlyWholeWordsAreReplaced() {
        let lex = lexicon(entry("Strut", [("stroot", "Strut")]))
        #expect(rewrite("stroots and unstroot and stroot_x", lex) == "stroots and unstroot and stroot_x")
    }

    @Test func punctuationAroundIsKept() {
        let lex = lexicon(entry("Strut", [("stroot", "Strut")]))
        #expect(rewrite("(stroot), \"stroot\"! stroot.", lex) == "(Strut), \"Strut\"! Strut.")
    }

    @Test func theLongestFormWins() {
        let lex = lexicon(
            entry("Short", [("peel", "PEEL")]),
            entry("Long", [("peel home", "Peel Home")])
        )
        #expect(rewrite("open peel home and peel", lex) == "open Peel Home and PEEL")
    }

    @Test func replacedTextIsNotRewrittenAgain() {
        let lex = lexicon(entry("A", [("one", "two")]), entry("B", [("two", "three")]))
        #expect(rewrite("one two", lex) == "two three")
    }

    @Test func spacesInAFormMatchAnyWhitespace() {
        let lex = lexicon(entry("Kubernetes", [("cooper nettys", "Kubernetes")]))
        #expect(rewrite("cooper   nettys", lex) == "Kubernetes")
    }

    @Test func entriesTurnedOffAreNeverApplied() {
        let lex = lexicon(entry("Strut", [("stroot", "Strut")], off: true))
        #expect(rewrite("stroot", lex) == "stroot")
    }

    @Test func noLexiconOrNoTextChangesNothing() {
        #expect(rewrite("peel send", nil) == "peel send")
        #expect(rewrite("peel send", .empty) == "peel send")
        #expect(rewrite("", lexicon(entry("A", [("a", "b")]))) == "")
    }

    @Test func aFormThatIsRegexSyntaxIsLiteral() {
        let lex = lexicon(entry("C++", [("c plus (plus)", "C++")]))
        #expect(rewrite("learn c plus (plus) today", lex) == "learn C++ today")
    }
}
