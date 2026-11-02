import Testing
@testable import PeelUI

/// Voice mode's phrases (docs/voice-mode.md): every command is introduced by
/// the wake word "peel" and ends the utterance; without it all is dictation.
struct VoiceCommandParserTests {
    private let parser = VoiceCommandParser()
    private let everything = Set(VoiceCommand.allCases)

    private func parse(_ text: String, _ accepted: Set<VoiceCommand>? = nil) -> VoiceCommandMatch {
        parser.parse(text, accepting: accepted ?? everything)
    }

    @Test func everyPrefixedPhraseIsRecognisedAsTheWholeUtterance() {
        for (command, phrases) in VoiceCommandPhrases.english.phrases {
            for phrase in phrases {
                let said = VoiceCommandPhrases.english.spoken(phrase, of: command)
                #expect(parse(said) == .command(command, textBefore: ""), "\(said)")
            }
        }
    }

    @Test func theRequestedPhrasesExist() {
        #expect(parse("peel send it") == .command(.send, textBefore: ""))
        #expect(parse("peel send message") == .command(.send, textBefore: ""))
        #expect(parse("peel over") == .command(.send, textBefore: ""))
        #expect(parse("peel stop") == .command(.stopSpeaking, textBefore: ""))
        #expect(parse("peel never mind") == .command(.discard, textBefore: ""))
        #expect(parse("peel cancel message") == .command(.discard, textBefore: ""))
        #expect(parse("peel say that again") == .command(.repeatReply, textBefore: ""))
        #expect(parse("peel read everything") == .command(.readAll, textBefore: ""))
        #expect(parse("peel cancel the agent") == .command(.stopAgent, textBefore: ""))
        #expect(parse("peel goodbye") == .command(.deactivate, textBefore: ""))
        #expect(parse("peel exit voice mode") == .command(.deactivate, textBefore: ""))
        #expect(parse("peel end voice session") == .command(.deactivate, textBefore: ""))
    }

    @Test func bareCommandsAreDictation() {
        for bare in ["send", "send it", "stop", "over", "scratch that", "mute", "unmute", "repeat that", "skip",
                     "read it all", "stop the agent", "goodbye", "end voice mode", "never mind"] {
            #expect(parse(bare) == .none, "\(bare)")
        }
    }

    @Test func trailingCommandKeepsTheTextBefore() {
        #expect(parse("add a login page to the backlog peel send")
            == .command(.send, textBefore: "add a login page to the backlog"))
        #expect(parse("Start the nightly job, Peel, send it.")
            == .command(.send, textBefore: "Start the nightly job"))
        #expect(parse("no wait peel scratch that") == .command(.discard, textBefore: "no wait"))
        #expect(parse("remember the milk peel mute") == .command(.mute, textBefore: "remember the milk"))
    }

    @Test func aCommandInTheMiddleDoesNotFire() {
        #expect(parse("peel send it to the team tomorrow") == .none)
        #expect(parse("tell peel to stop the build and then continue") == .none)
        #expect(parse("peel mute the other channel please") == .none)
    }

    @Test func proseWithPeelIsDictation() {
        #expect(parse("peel the potatoes and then send") == .none)
        #expect(parse("I need to peel an orange") == .none)
        #expect(parse("the peel") == .none)
        #expect(parse("peel") == .none)
    }

    @Test func longerPhraseWins() {
        #expect(parse("peel stop the agent") == .command(.stopAgent, textBefore: ""))
        #expect(parse("peel stop voice mode") == .command(.deactivate, textBefore: ""))
        #expect(parse("peel send it") == .command(.send, textBefore: ""))
    }

    @Test func wakeWordVariantsCountOnlyBeforeACommand() {
        #expect(parse("pill send") == .command(.send, textBefore: ""))
        #expect(parse("add a screen peal send") == .command(.send, textBefore: "add a screen"))
        #expect(parse("feel stop") == .command(.stopSpeaking, textBefore: ""))
        #expect(parse("pill") == .none)
        #expect(parse("I feel fine") == .none)
        #expect(parse("a pill for the cat") == .none)
    }

    @Test func caseAndPunctuationDoNotMatter() {
        #expect(parse("  PEEL, STOP THE AGENT. ") == .command(.stopAgent, textBefore: ""))
        #expect(parse("Peel: end   voice-mode") == .command(.deactivate, textBefore: ""))
        #expect(parse("Add a login screen. Peel, send message.") == .command(.send, textBefore: "Add a login screen."))
    }

    @Test func activationNeedsNoPrefix() {
        #expect(parse("  Hey, Peel! ") == .command(.activate, textBefore: ""))
        #expect(parse("voice mode") == .command(.activate, textBefore: ""))
        #expect(parse("start voice mode") == .command(.activate, textBefore: ""))
        #expect(parse("peel start voice mode") == .command(.activate, textBefore: ""))
        // Whole utterance only, unless the wake listener makes it trailing.
        #expect(parse("tell me about voice mode") == .none)
        var table = VoiceCommandPhrases.english
        table.trailing.insert(.activate)
        #expect(VoiceCommandParser(table: table).parse("ok hey peel", accepting: [.activate])
            == .command(.activate, textBefore: "ok"))
    }

    @Test func dictatingContext() {
        let accepts = VoiceContext.dictating.accepts
        #expect(parse("peel send", accepts) == .command(.send, textBefore: ""))
        #expect(parse("peel mute", accepts) == .command(.mute, textBefore: ""))
        #expect(parse("hey peel", accepts) == .none)
        #expect(parse("peel stop", accepts) == .none)
        #expect(parse("peel unmute", accepts) == .none)
        #expect(parse("peel skip", accepts) == .none)
    }

    @Test func speakingContext() {
        let accepts = VoiceContext.speaking.accepts
        for (said, command) in [("peel stop", VoiceCommand.stopSpeaking), ("peel repeat", .repeatReply), ("peel skip", .skip),
                                ("peel read it all", .readAll), ("peel stop the agent", .stopAgent), ("peel mute", .mute),
                                ("peel end voice mode", .deactivate)] {
            #expect(parse(said, accepts) == .command(command, textBefore: ""), "\(said)")
        }
        #expect(parse("peel send", accepts) == .none)
        #expect(parse("peel scratch that", accepts) == .none)
        #expect(parse("peel unmute", accepts) == .none)
    }

    @Test func mutedContextHearsOnlyUnmuteAndEnd() {
        let accepts = VoiceContext.muted.accepts
        #expect(accepts == [.unmute, .deactivate])
        #expect(parse("peel unmute", accepts) == .command(.unmute, textBefore: ""))
        #expect(parse("some chatter in the car peel unmute", accepts) == .command(.unmute, textBefore: "some chatter in the car"))
        #expect(parse("peel end voice mode", accepts) == .command(.deactivate, textBefore: ""))
        #expect(parse("peel send", accepts) == .none)
        #expect(parse("peel stop", accepts) == .none)
        #expect(parse("peel mute", accepts) == .none)
    }

    @Test func waitingContext() {
        let accepts = VoiceContext.waiting.accepts
        #expect(parse("peel stop the agent", accepts) == .command(.stopAgent, textBefore: ""))
        #expect(parse("peel send", accepts) == .none)
        #expect(parse("peel stop", accepts) == .none)
    }

    @Test func contextualStringsArePrefixed() {
        let all = VoiceCommandPhrases.english.all
        #expect(all.contains("peel send"))
        #expect(all.contains("peel end voice mode"))
        #expect(all.contains("peel unmute"))
        #expect(all.contains("hey peel"))
        #expect(!all.contains("send"))
    }

    @Test func emptyAndPunctuationOnlyFindNothing() {
        #expect(parse("") == .none)
        #expect(parse(" ... ") == .none)
    }

    @Test func normalizeLowercasesAndCollapses() {
        #expect(VoiceCommandParser.normalize("  Send,   IT!! ") == "send it")
    }
}
