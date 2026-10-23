import AgentKit
import Foundation
import Testing
@testable import PeelUI

/// What Peel reads of strut's dictation vocabulary (stakwork/strut#301): the
/// lexicon for the Vocabulary window, and what a correction learned. The
/// judging itself is strut's and tested there (`src/audio/lingo.test.ts`).
struct LingoTests {
    /// `memory/lexicon`'s output as stakwork/strut#297 and #301 document it.
    private static let lexiconReply = #"""
        {"lingo_type":"Lingo","mishearing":"heard_as","entities":[
          {"ref_id":"e2","type":"Lingo","name":"Bitcoin","written":["Bitcoin","BTC"],
           "heard":[{"ref_id":"f2","value":"bee tee see","form":"BTC","created_at":"2026-10-23T14:02:11.000Z"},
                    {"ref_id":"f9","value":"bit coin","form":null,"created_at":"2026-10-23T14:03:00.000Z"}],
           "dictation_off":false,"facts":4,"updated_at":"2026-10-23T14:03:00.000Z","known_by_user":true},
          {"ref_id":"e1","type":"Organization","name":"Stakwork","written":["Stakwork"],
           "heard":[{"ref_id":"f1","value":"stack work","form":null}],"dictation_off":true,"facts":9}],
         "undone":[]}
        """#

    @Test func readsTheVocabulary() throws {
        let lexicon = LingoLexicon(lexicon: try JSONValue(parsing: Self.lexiconReply))
        #expect(lexicon.entries.map(\.name) == ["Bitcoin", "Stakwork"])
        #expect(lexicon.entries[0].written == ["Bitcoin", "BTC"])
        #expect(lexicon.entries[0].heard == [.init(refID: "f2", value: "bee tee see", form: "BTC"),
                                             .init(refID: "f9", value: "bit coin", form: nil)])
        // A taught word, against a known organisation that also has mishearings.
        #expect(lexicon.entries.map(\.isLingo) == [true, false])
        #expect(lexicon.entries.map(\.dictationOff) == [false, true])
    }

    @Test func readsWhatACorrectionLearned() throws {
        let output = try JSONValue(parsing: #"""
            {"learned":[{"heard":"p eight","written":"P8","undo":["e9"]},
                        {"heard":"stack work","written":"Stakwork","undo":[]}]}
            """#)
        #expect(LingoLearned.list(from: output) == [
            .init(heard: "p eight", written: "P8", undo: ["e9"]),
            // Strut already had it: nothing to undo.
            .init(heard: "stack work", written: "Stakwork", undo: []),
        ])
        #expect(LingoLearned.list(from: try JSONValue(parsing: #"{"learned":[]}"#)).isEmpty)
    }
}
