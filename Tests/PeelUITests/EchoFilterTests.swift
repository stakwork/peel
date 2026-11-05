import Foundation
import Testing
@testable import PeelUI

/// What Peel says aloud is told from the user (`EchoFilter`).
struct EchoFilterTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)
    private let reply = ["I have added the login page to the backlog.", "Say read it all for the rest."]

    private func speaking() -> EchoFilter {
        var filter = EchoFilter()
        filter.speechStarted(chunks: reply, now: t0)
        return filter
    }

    @Test func aRunOfThreeWordsOfTheSpeechIsAnEcho() {
        let filter = speaking()
        #expect(filter.isEcho("added the login page", now: t0))
        #expect(filter.isEcho("Hello there, ADDED the login", now: t0))
        #expect(filter.isEcho("page to the backlog say read it", now: t0.addingTimeInterval(1)))
    }

    @Test func otherWordsAreNotAnEcho() {
        let filter = speaking()
        #expect(!filter.isEcho("send the report to Bob", now: t0))
        #expect(!filter.isEcho("login screen", now: t0))
        #expect(!filter.isEcho("", now: t0))
    }

    @Test func aShortTranscriptIsAnEchoWhenWhollyContained() {
        let filter = speaking()
        #expect(filter.isEcho("login page", now: t0))
        #expect(filter.isEcho("backlog", now: t0))
        #expect(!filter.isEcho("login backlog", now: t0))
    }

    @Test func notGuardingBeforeSpeechStarts() {
        let filter = EchoFilter()
        #expect(!filter.isGuarding(now: t0))
        #expect(!filter.isEcho("added the login page", now: t0))
    }

    @Test func tailEchoIsCaughtForAShortWhileAfterTheSpeech() {
        var filter = speaking()
        filter.speechEnded(now: t0.addingTimeInterval(5))
        #expect(!filter.speaking)
        #expect(filter.isGuarding(now: t0.addingTimeInterval(6)))
        #expect(filter.isEcho("added the login page", now: t0.addingTimeInterval(6)))
        #expect(!filter.isGuarding(now: t0.addingTimeInterval(6.6)))
        #expect(!filter.isEcho("added the login page", now: t0.addingTimeInterval(6.6)))
    }

    @Test func spokenTextCountsForThreeSecondsAfterItEnded() {
        var filter = speaking()
        filter.speechEnded(now: t0)
        filter.speechStarted(chunks: ["The build is green."], now: t0.addingTimeInterval(2))
        #expect(filter.isEcho("the build is green", now: t0.addingTimeInterval(2.5)))
        #expect(filter.isEcho("added the login page", now: t0.addingTimeInterval(2.5)))
        #expect(!filter.isEcho("added the login page", now: t0.addingTimeInterval(3.5)))
        #expect(filter.isEcho("the build is green", now: t0.addingTimeInterval(3.5)))
    }

    @Test func stoppingReplacesWhatIsBeingSpoken() {
        var filter = speaking()
        filter.speechStarted(chunks: ["Something else entirely."], now: t0.addingTimeInterval(1))
        #expect(filter.isEcho("something else entirely", now: t0.addingTimeInterval(1)))
        #expect(filter.isEcho("added the login page", now: t0.addingTimeInterval(1)))
    }

    @Test func currentlyContainsOnlyTheTextBeingSpoken() {
        var filter = speaking()
        #expect(filter.currentlyContains("login page"))
        #expect(!filter.currentlyContains("peel stop"))
        #expect(!filter.currentlyContains(""))
        filter.speechEnded(now: t0)
        #expect(!filter.currentlyContains("login page"))
    }

    @Test func resetForgetsEverything() {
        var filter = speaking()
        filter.reset()
        #expect(!filter.speaking)
        #expect(!filter.isEcho("added the login page", now: t0))
    }

    @Test func theRuleIsPure() {
        #expect(EchoFilter.matches(["a", "b", "c"], in: ["x", "a", "b", "c", "y"]))
        #expect(!EchoFilter.matches(["a", "c", "b"], in: ["x", "a", "b", "c", "y"]))
        #expect(!EchoFilter.matches([], in: ["a"]))
        #expect(!EchoFilter.matches(["a"], in: []))
    }
}
