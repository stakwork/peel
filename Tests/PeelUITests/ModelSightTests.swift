import Foundation
import Testing
@testable import PeelUI

/// The agent chat's per-picture "Let the model see this picture" switch.
struct ModelSightTests {
    let agent = ComposerID.chat("02agent")
    let picture = URL(fileURLWithPath: "/tmp/photo.png")
    let other = URL(fileURLWithPath: "/tmp/other.jpg")
    let document = URL(fileURLWithPath: "/tmp/notes.pdf")

    @Test func everyPictureStartsOff() {
        let sight = ModelSight()
        #expect(!sight.allows(picture, in: agent))
    }

    @Test func onlyPicturesCanBeTurnedOn() {
        var sight = ModelSight()
        sight.set(true, for: document, in: agent)
        sight.set(true, for: picture, in: agent)
        #expect(!sight.allows(document, in: agent) && sight.allows(picture, in: agent))
        #expect(ModelSight.offers(picture) && ModelSight.offers(other) && !ModelSight.offers(document))
    }

    @Test func eachFileAndComposerHasItsOwn() {
        var sight = ModelSight()
        sight.set(true, for: picture, in: agent)
        #expect(!sight.allows(other, in: agent) && !sight.allows(picture, in: .chat("02kate")))
        sight.set(false, for: picture, in: agent)
        #expect(!sight.allows(picture, in: agent))
    }

    /// Removing the file takes its switch with it, so a picture added again starts off.
    @Test func removingTheFileDropsItsState() {
        var sight = ModelSight()
        sight.set(true, for: picture, in: agent)
        sight.drop(picture, from: agent)
        #expect(!sight.allows(picture, in: agent) && sight == ModelSight())
    }

    @Test func sendingTakesTheOnesThatAreOnAndForgetsAll() {
        var sight = ModelSight()
        sight.set(true, for: picture, in: agent)
        // A switch for a file no longer in the tray is not sent.
        sight.set(true, for: other, in: agent)
        let taken = sight.take([picture, document], from: agent)
        #expect(taken == [picture] && sight == ModelSight())
    }

    @Test func aFileThatDidNotGoKeepsItsSwitch() {
        var sight = ModelSight()
        sight.restore([picture], in: agent)
        #expect(sight.allows(picture, in: agent))
        sight.restore([], in: .chat("02kate"))
        #expect(sight == { var expected = ModelSight(); expected.set(true, for: picture, in: agent); return expected }())
    }

    @Test func wordsSayWhatEachSideMeans() {
        #expect(ModelSight.title == "Let the model see this picture")
        #expect(ModelSight.help == "Off: only the text read from it goes to the model. On: the picture is sent to your model provider.")
    }
}

/// An attachment read folds into the agent's reads like the chat reads do.
struct AttachmentReadRowTests {
    @Test func theKindIsKnown() {
        #expect(AgentReads.Kind("attachments.read") == .attachment)
        #expect(AgentReads.Kind("attachments.write") == nil)
    }
}
