import AgentKit
import Foundation
import Testing
@testable import PeelUI

/// Dictation's vocabulary (docs/dictation-lingo.md): the rewrite before the
/// text is typed, and what an edit of it teaches.
struct LingoTests {
    /// Everyday words, as the spell checker would say.
    private static let common: Set<String> = [
        "a", "i", "ask", "the", "team", "about", "stack", "work", "their", "there", "eight", "meeting", "fix",
        "bit", "coin", "sat", "peel", "for", "to", "is", "on", "we", "go", "hive", "and", "apple", "pie", "think",
        "so", "now", "number", "it", "push",
    ]
    private static let isCommon: IsCommonWord = { common.contains($0) }

    private static let lexicon = LingoLexicon(entries: [
        .init(refID: "e1", type: "Organization", name: "Stakwork", written: ["Stakwork"],
              heard: [.init(refID: "f1", value: "stack work")]),
        .init(refID: "e2", type: "Lingo", name: "Bitcoin", written: ["Bitcoin", "BTC"],
              heard: [.init(refID: "f2", value: "bee tee see", form: "BTC")]),
        .init(refID: "e3", type: "Project", name: "Sphinx", written: ["Sphinx"],
              heard: [.init(refID: "f3", value: "fix")]),
        .init(refID: "e4", type: "Project", name: "Peel", written: ["Peel"]),
        .init(refID: "e5", type: "Lingo", name: "LSAT", written: ["LSAT"],
              heard: [.init(refID: "f5", value: "el sat")], dictationOff: true),
        // An agent stored it in its own casing; nobody taught it to dictation.
        .init(refID: "e6", type: "Organization", name: "github", written: ["github"]),
    ])

    // MARK: The rewrite

    @Test(arguments: [
        // A mishearing, with the punctuation around it kept.
        ("Ask the stack work team.", "Ask the Stakwork team."),
        // One standing for an alias.
        ("send it in bee tee see", "send it in BTC"),
        // A single everyday word is never rewritten: "fix" stays "fix".
        ("we fix it", "we fix it"),
        // Casing for a written form that is not an everyday word; "peel" stays.
        ("ask stakwork about bitcoin and peel", "ask Stakwork about Bitcoin and peel"),
        // Off for dictation: left as it is.
        ("el sat is on", "el sat is on"),
        // A new spelling of a taught name: its letters, or nearly ("Stockwork").
        ("Hello, I work for Stockwork.", "Hello, I work for Stakwork."),
        ("I work for stackwork", "I work for Stakwork"),
        ("I work for StackWork now", "I work for Stakwork now"),
        // Not a different word: "stadium" and "network" stay.
        ("I work at the stadium network", "I work at the stadium network"),
        // Not across a sentence break.
        ("We need a stack. Work starts", "We need a stack. Work starts"),
        // A name nobody taught dictation keeps the user's casing.
        ("push it to GitHub", "push it to GitHub"),
        // Nothing known: untouched, spacing and all.
        ("  nothing  here ", "  nothing  here "),
    ])
    func rewrites(heard: String, typed: String) {
        #expect(LingoRewriter.rewrite(heard, with: Self.lexicon, isCommon: Self.isCommon).text == typed)
    }

    @Test func theRewriteSaysWhatItChanged() {
        let result = LingoRewriter.rewrite("the stack work team", with: Self.lexicon, isCommon: Self.isCommon)
        #expect(result.changes == [.init(heard: "stack work", written: "Stakwork")])
    }

    // MARK: Learning from an edit

    @Test(arguments: [
        // Dictation broke a name up: learned.
        ("Ask the stack work team", "Ask the Stakwork team", [LingoLesson.misheard(heard: "stack work", written: "Stakwork")]),
        // Spelled out what was said as P8: learned (nobody writes "p eight").
        ("send p eight now", "send P8 now", [.misheard(heard: "p eight", written: "P8")]),
        // Letters run apart: learned.
        ("the k p i number", "the KPI number", [.misheard(heard: "k p i", written: "KPI")]),
        // Casing only, on a name not known yet: learned.
        ("ask hivemind now", "ask HiveMind now", [.misheard(heard: "hivemind", written: "HiveMind")]),
        // Casing on a known name: the rewrite already cases it, nothing new.
        ("ask stakwork now", "ask Stakwork now", [.nothing]),
        // Dictation wrote PH for P8: PH is something you could mean, so nothing is learned.
        ("send PH now", "send P8 now", [.nothing]),
        // An everyday swap.
        ("their team", "there team", [.nothing]),
        // Two right ways to write one thing.
        ("send BTC now", "send Bitcoin now", [.nothing]),
        // A changed mind: a name that sounds nothing like what was said.
        ("ask the meeting team", "ask the Stakwork team", [.nothing]),
        // Capitalising an everyday word or a letter teaches nothing.
        ("i think so", "I think so", [.nothing]),
        ("apple pie", "Apple pie", [.nothing]),
        // One name swapped for another like it: a different person, not a mishearing.
        ("ask jon now", "ask Jen now", [.nothing]),
        // A word turned off for dictation is left alone.
        ("the el sat token", "the LSAT token", [.nothing]),
        // A one-word dictation can still teach.
        ("hivemind", "HiveMind", [.misheard(heard: "hivemind", written: "HiveMind")]),
        // A long word misspelt: learned ("Stackwork", "stockwork" → Stakwork).
        ("Hello I work for Stackwork", "Hello I work for Stakwork", [.misheard(heard: "Stackwork", written: "Stakwork")]),
        ("I work for stockwork", "I work for Stakwork", [.misheard(heard: "stockwork", written: "Stakwork")]),
        // A different word altogether is not.
        ("I work for stadium", "I work for Stakwork", [.nothing]),
        // A short name swapped for one like it is a different person.
        ("ask sarah now", "ask Sara now", [.nothing]),
        // A cut at the end, kept the rest.
        ("ask the team about it", "ask the team", [.nothing]),
    ])
    func classifies(typed: String, edited: String, lessons: [LingoLesson]) {
        #expect(LingoClassifier.lessons(typed: typed, edited: edited, lexicon: Self.lexicon, isCommon: Self.isCommon) == lessons)
    }

    @Test func aRewriteOfTheWholeThingTeachesNothing() {
        #expect(LingoClassifier.lessons(typed: "ask the stack work team", edited: "Let's talk tomorrow instead",
                                        lexicon: Self.lexicon, isCommon: Self.isCommon).isEmpty)
    }

    @Test func anUndonePairIsNotLearnedAgain() {
        var lexicon = Self.lexicon
        lexicon.undone = [.init(value: "p eight", written: "P8")]
        #expect(LingoClassifier.lessons(typed: "send p eight now", edited: "send P8 now", lexicon: lexicon,
                                        isCommon: Self.isCommon) == [.nothing])
    }

    // MARK: Strut's steps

    /// `memory/lexicon`'s output as stakwork/strut#297 documents it.
    private static let lexiconReply = #"""
        {"entities":[
          {"ref_id":"e2","type":"Lingo","name":"Bitcoin","written":["Bitcoin","BTC"],
           "heard":[{"ref_id":"f2","value":"bee tee see","form":"BTC","created_at":"2026-10-23T14:02:11.000Z"},
                    {"ref_id":"f9","value":"bit coin","form":null,"created_at":"2026-10-23T14:03:00.000Z"}],
           "dictation_off":false,"facts":4,"updated_at":"2026-10-23T14:03:00.000Z","known_by_user":true},
          {"ref_id":"e5","type":"Lingo","name":"LSAT","written":["LSAT"],"heard":[],"dictation_off":true,"facts":1}],
         "undone":[{"ref_id":"f7","value":"el sat","form":null,"entity":{"ref_id":"e5","name":"LSAT"},"undone_at":"2026-10-23T14:05:00.000Z"}]}
        """#

    @Test func readsStrutsLexicon() throws {
        let lexicon = LingoLexicon(lexicon: try JSONValue(parsing: Self.lexiconReply))
        #expect(lexicon.entries.map(\.name) == ["Bitcoin", "LSAT"])
        #expect(lexicon.entries[0].written == ["Bitcoin", "BTC"])
        #expect(lexicon.entries[0].heard == [.init(refID: "f2", value: "bee tee see", form: "BTC"),
                                             .init(refID: "f9", value: "bit coin", form: nil)])
        #expect(lexicon.entries[1].dictationOff)
        #expect(lexicon.undone == [.init(value: "el sat", written: "LSAT")])
        #expect(LingoRewriter.rewrite("a bit coin", with: lexicon, isCommon: Self.isCommon).text == "a Bitcoin")
    }

    @Test func aLearnSaysOnlyThePairOnTheRightEntity() {
        // A known name: on its entity, with the alias as its form.
        let alias = LingoWrites.learn(heard: "bee see", written: "BTC", in: Self.lexicon)
        #expect(alias["episode"]?.string == "Dictation: corrected “bee see” to “BTC”.")
        let fact = alias["facts"]?.array?.first
        #expect(fact?["subject"]?["ref_id"]?.string == "e2")
        #expect(fact?["predicate"]?.string == "heard_as")
        #expect(fact?["value"]?.string == "bee see")
        #expect(fact?["form"]?.string == "BTC")
        // An unknown word: a new Lingo, no form.
        let new = LingoWrites.learn(heard: "p eight", written: "P8", in: Self.lexicon)
        #expect(new["facts"]?.array?.first?["subject"] == ["type": "Lingo", "name": "P8"])
        #expect(new["facts"]?.array?.first?["form"] == nil)
    }

    @Test func undoForgetsWhatTheLearnMade() throws {
        let newEntity = try JSONValue(parsing: #"{"entities":[{"ref_id":"e9","status":"created"}],"facts":[{"ref_id":"f9","status":"created"}]}"#)
        #expect(LingoWrites.undoIDs(of: newEntity) == ["e9"])
        let newFact = try JSONValue(parsing: #"{"entities":[{"ref_id":"e1","status":"matched"}],"facts":[{"ref_id":"f9","status":"created"}]}"#)
        #expect(LingoWrites.undoIDs(of: newFact) == ["f9"])
        let known = try JSONValue(parsing: #"{"entities":[{"ref_id":"e1","status":"matched"}],"facts":[{"ref_id":"f1","status":"existing"}]}"#)
        #expect(LingoWrites.undoIDs(of: known).isEmpty)
    }
}

