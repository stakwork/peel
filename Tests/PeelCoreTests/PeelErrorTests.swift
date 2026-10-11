import Foundation
import Testing
@testable import PeelCore

/// Problem lines (`PeelError.problem`): every failure the app shows reads
/// as a sentence, with a capital and a full stop, whatever shape its words
/// arrived in.
struct PeelErrorTests {
    @Test func aFragmentBecomesASentence() {
        #expect(PeelError.problem(Engine.Failure.notConnected) == "Not connected to the server.")
        #expect(PeelError.problem(Engine.Failure.balanceUnknown) == "The balance is not known yet; connect first.")
        #expect(PeelError.problem(URLError(.cannotConnectToHost)) == "The server could not be reached.")
        #expect(PeelError.problem("that's not it") == "That's not it.")
    }

    @Test func aSentenceStaysAsItIs() {
        for sentence in [
            "Wrong PIN. Try again.", "That doesn't look like a Sphinx invite.", "Really?", "Done!", "Wait…",
            "The operation couldn’t be completed. (NSURLErrorDomain error -1.)",
        ] {
            #expect(PeelError.problem(sentence) == sentence)
            #expect(PeelError.problem(PeelError(sentence)) == sentence)
        }
    }

    @Test func aNameAtTheStartKeepsItsCase() {
        #expect(PeelError.problem("photo.jpg is not a picture") == "photo.jpg is not a picture.")
        #expect(PeelError.problem("example.com is not on the internet") == "example.com is not on the internet.")
        #expect(PeelError.problem("iCloud is off") == "iCloud is off.")
        #expect(PeelError.problem("Keychain write failed") == "Keychain write failed.")
    }

    @Test func punctuationAtTheEnd() {
        #expect(PeelError.problem("the local database failed (SQLite error 5)")
            == "The local database failed (SQLite error 5).")
        #expect(PeelError.problem("  the disk is full \n") == "The disk is full.")
        #expect(PeelError.problem("checking mentions: the disk is full") == "Checking mentions: the disk is full.")
        #expect(PeelError.problem("the server said:") == "The server said.")
        #expect(PeelError.problem("it said “try later.”") == "It said “try later.”")
    }

    @Test func couldNotNamesWhatFailed() {
        #expect(PeelError.problem(Engine.Failure.notConnected, couldNot: "send")
            == "Could not send. Not connected to the server.")
        #expect(PeelError.problem("Not signed in.", couldNot: "boost") == "Could not boost. Not signed in.")
        #expect(PeelError.problem("photo.jpg is too large", couldNot: "send photo.jpg")
            == "Could not send photo.jpg. photo.jpg is too large.")
        #expect(PeelError.problem("", couldNot: "save the file") == "Could not save the file.")
    }

    @Test func emptyWordsStayEmpty() {
        #expect(PeelError.problem("") == "")
        #expect(PeelError.problem("  ") == "")
    }

    /// Joined sentences, or a line that is already a problem, pass through
    /// again unchanged: a reason can be worded where it fails and shown where
    /// it lands.
    @Test func itIsIdempotent() {
        let once = PeelError.problem(Engine.Failure.insufficientBalance, couldNot: "pay")
        #expect(PeelError.problem(once) == once)
        let joined = ["a.png is not a picture", "b.gif is too large"].map { PeelError.problem($0) }.joined(separator: " ")
        #expect(PeelError.problem(joined, couldNot: "attach")
            == "Could not attach. a.png is not a picture. b.gif is too large.")
    }
}
