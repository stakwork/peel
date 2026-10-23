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

    /// `dictation/models`' reply as strut's `_models.ts` documents it.
    @Test func readsTheModels() throws {
        let output = try JSONValue(parsing: #"""
            {"models":[
              {"id":"zipformer-en-kroko","kind":"speech","bytes":57267600,"description":"Kroko","state":"installed","selected":true},
              {"id":"parakeet-tdt-en-0.6b-v2","kind":"speech","bytes":482468385,"description":"Parakeet","state":"downloading","progress":0.42,"selected":false},
              {"id":"qwen3-0.6b-q4","kind":"fixer","bytes":396705472,"description":"small","state":"available","selected":false,"error":"checksum mismatch"},
              {"id":"qwen3-1.7b-q4","kind":"fixer","bytes":1107409472,"description":"large","state":"downloading","selected":true},
              {"id":"whisper","kind":"translator","bytes":1,"description":"","state":"available","selected":false}]}
            """#)
        let models = DictationModel.list(from: output)
        #expect(models.map(\.id) == ["zipformer-en-kroko", "parakeet-tdt-en-0.6b-v2", "qwen3-0.6b-q4", "qwen3-1.7b-q4"])
        #expect(models[0] == .init(id: "zipformer-en-kroko", kind: .speech, bytes: 57_267_600, description: "Kroko",
                                   state: .installed, selected: true))
        #expect(models[1].state == .downloading && models[1].progress == 0.42 && !models[1].selected)
        #expect(models[2].kind == .fixer && models[2].error == "checksum mismatch")
        // Downloading with no progress yet.
        #expect(models[3].progress == nil && models[3].selected)
        #expect(DictationModel.list(from: try JSONValue(parsing: #"{"error":"no stt"}"#)).isEmpty)
    }
}

/// When an edit to dictated text is done, and what it is: sent once, as
/// strut runs a model on it.
struct DictationEditTests {
    /// "Ask the stack work team" typed between "Hi. " and "!", the caret after it.
    private static func edit() throws -> DictationEdit {
        try #require(DictationEdit(value: "Hi. Ask the stack work team!", typed: "Ask the stack work team", caret: 27))
    }

    @Test func anEditLeftAloneForTwoSecondsIsDone() throws {
        var edit = try Self.edit()
        #expect(edit.read("Hi. Ask the stack work team!", at: .seconds(1)) == .watch)
        #expect(edit.read("Hi. Ask the Stakwork team!", at: .seconds(2)) == .watch)
        #expect(edit.read("Hi. Ask the Stakwork team!", at: .seconds(3.5)) == .watch)
        #expect(edit.read("Hi. Ask the Stakwork team!", at: .seconds(4)) == .done)
        #expect(edit.edited == "Ask the Stakwork team")
    }

    @Test func eachChangeStartsTheWaitAgain() throws {
        var edit = try Self.edit()
        #expect(edit.read("Hi. Ask the  team!", at: .seconds(1)) == .watch)
        #expect(edit.read("Hi. Ask the Stak team!", at: .seconds(2.5)) == .watch)
        #expect(edit.read("Hi. Ask the Stakwork team!", at: .seconds(4)) == .watch)
        #expect(edit.read("Hi. Ask the Stakwork team!", at: .seconds(5.5)) == .watch)
        #expect(edit.read("Hi. Ask the Stakwork team!", at: .seconds(6)) == .done)
    }

    @Test func nothingChangedIsNothingToSend() throws {
        var edit = try Self.edit()
        for second in 1...10 { #expect(edit.read("Hi. Ask the stack work team!", at: .seconds(second)) == .watch) }
        #expect(edit.edited == nil)
    }

    @Test func returnEmptyingTheFieldKeepsTheFixBeforeIt() throws {
        var edit = try #require(DictationEdit(value: "stack work", typed: "stack work", caret: 10))
        #expect(edit.read("Stakwork", at: .seconds(0.5)) == .watch)
        #expect(edit.read("", at: .seconds(1)) == .done)
        #expect(edit.edited == "Stakwork")
    }

    @Test func aChangeAroundTheTextIsNotTheEdit() throws {
        var edit = try Self.edit()
        // "Hi. " changed too: wait for the field to read as Peel left it around the text.
        #expect(edit.read("Hello. Ask the Stakwork team!", at: .seconds(1)) == .watch)
        #expect(edit.read("Hello. Ask the Stakwork team!", at: .seconds(4)) == .watch)
        #expect(edit.edited == nil)
    }

    @Test func notWhereTheCaretSays() {
        #expect(DictationEdit(value: "Hi. Ask the stack work team!", typed: "Ask the stack work team", caret: 10) == nil)
        #expect(DictationEdit(value: "short", typed: "longer than the field", caret: 5) == nil)
    }
}
