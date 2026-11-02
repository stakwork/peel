import Testing
@testable import PeelUI

/// Voice mode's phrases (docs/voice-mode.md): trailing ones end a sentence,
/// the controls are the whole utterance.
struct VoiceCommandParserTests {
    private let parser = VoiceCommandParser()
    private let everything = Set(VoiceCommand.allCases)

    private func parse(_ text: String, _ accepted: Set<VoiceCommand>? = nil) -> VoiceCommandMatch {
        parser.parse(text, accepting: accepted ?? everything)
    }

    @Test func everyPhraseIsRecognisedAsTheWholeUtterance() {
        for (command, phrases) in VoiceCommandPhrases.english.phrases {
            for phrase in phrases {
                #expect(parse(phrase) == .command(command, textBefore: ""), "\(phrase)")
            }
        }
    }

    @Test func trailingSendKeepsTheTextBefore() {
        #expect(parse("Start the nightly job on the staging server, send it")
            == .command(.send, textBefore: "Start the nightly job on the staging server"))
        #expect(parse("add a login screen over") == .command(.send, textBefore: "add a login screen"))
        #expect(parse("Add a login screen. Send message.") == .command(.send, textBefore: "Add a login screen."))
    }

    @Test func trailingDiscardKeepsTheTextBefore() {
        #expect(parse("no wait scratch that") == .command(.discard, textBefore: "no wait"))
    }

    @Test func longerPhraseWins() {
        #expect(parse("let us start over") == .command(.discard, textBefore: "let us"))
    }

    @Test func aPhraseInTheMiddleDoesNotFire() {
        #expect(parse("please send it to the team tomorrow") == .none)
        #expect(parse("I want to never mind the other thing and continue") == .none)
        #expect(parse("over the hill and far away") == .none)
    }

    @Test func controlsAreOnlyTheWholeUtterance() {
        #expect(parse("stop") == .command(.stopSpeaking, textBefore: ""))
        #expect(parse("please stop the build") == .none)
        #expect(parse("tell me about repeat") == .none)
        #expect(parse("skip this one") == .none)
        #expect(parse("now read it all") == .none)
    }

    @Test func caseAndPunctuationDoNotMatter() {
        #expect(parse("  Hey, Peel! ") == .command(.activate, textBefore: ""))
        #expect(parse("STOP THE AGENT.") == .command(.stopAgent, textBefore: ""))
        #expect(parse("Exit   voice-mode") == .command(.deactivate, textBefore: ""))
        #expect(parse("Goodbye, Peel.") == .command(.deactivate, textBefore: ""))
    }

    @Test func onlyAcceptedCommandsCount() {
        #expect(parse("hey peel", VoiceContext.dictating.accepts) == .none)
        #expect(parse("hey peel", VoiceContext.armed.accepts) == .command(.activate, textBefore: ""))
        #expect(parse("send it", VoiceContext.speaking.accepts) == .none)
        #expect(parse("stop", VoiceContext.speaking.accepts) == .command(.stopSpeaking, textBefore: ""))
        #expect(parse("stop", VoiceContext.dictating.accepts) == .none)
    }

    @Test func emptyAndPunctuationOnlyFindNothing() {
        #expect(parse("") == .none)
        #expect(parse(" ... ") == .none)
    }

    @Test func normalizeLowercasesAndCollapses() {
        #expect(VoiceCommandParser.normalize("  Send,   IT!! ") == "send it")
    }
}
