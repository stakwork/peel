import Foundation
import Testing
@testable import PeelCore

/// Which download failures are retried, how often, and what an automatic
/// fetch may do for each kind of attachment with Auto download media on or off.
struct MediaFetchTests {
    @Test func networkFailuresAreTransient() {
        for code in [URLError.Code.notConnectedToInternet, .timedOut, .cancelled, .networkConnectionLost, .cannotConnectToHost,
                     .dnsLookupFailed, .badServerResponse] {
            #expect(MediaFetch.isTransient(URLError(code)), "\(code)")
        }
        #expect(MediaFetch.isTransient(CancellationError()))
        #expect(!MediaFetch.isTransient(URLError(.badURL)))
        #expect(!MediaFetch.isTransient(URLError(.unsupportedURL)))
    }

    @Test func serverAnswersAreTransientOnlyWhenTheFileMayStillComeOrTheServerIsBusy() {
        for status in [404, 408, 429, 500, 502, 503, 504] {
            #expect(MediaFetch.isTransient(MemesServer.Failure.refused("the download", status)), "\(status)")
            #expect(MediaFetch.isTransient(Web.Failure.refused("the download", status)), "\(status)")
        }
        for status in [301, 400, 401, 402, 403, 410, 413, 451] {
            #expect(!MediaFetch.isTransient(MemesServer.Failure.refused("the download", status)), "\(status)")
        }
        #expect(MediaFetch.isTransient(MemesServer.Failure.unreadableReply("the download")))
    }

    @Test func aSignInThatFailsIsTransient() {
        #expect(MediaFetch.isTransient(MemesServer.Failure.refused("sign-in", 503)))
        #expect(MediaFetch.isTransient(MemesServer.Failure.refused("the signed challenge", 401)))
        #expect(MediaFetch.isTransient(MemesServer.Failure.unreadableReply("sign-in")))
        #expect(!MediaFetch.isTransient(MemesServer.Failure.shortChallenge(4)))
    }

    @Test func whatNoRetryMendsIsPermanent() {
        #expect(!MediaFetch.isTransient(Engine.Failure.untrustedMediaHost("evil.example")))
        #expect(!MediaFetch.isTransient(Engine.Failure.notAnAttachment))
        #expect(!MediaFetch.isTransient(Engine.Failure.attachmentWithoutKey))
        #expect(!MediaFetch.isTransient(MemesServer.Failure.unreadableHost("x")))
        #expect(!MediaFetch.isTransient(TooLarge(limit: 10)))
        #expect(!MediaFetch.isTransient(PeelError("the file did not decrypt")))
    }

    @Test func retriesBackOffThreeTimesThenStop() {
        #expect(MediaFetch.retryDelay(attempt: 1) == 2)
        #expect(MediaFetch.retryDelay(attempt: 2) == 10)
        #expect(MediaFetch.retryDelay(attempt: 3) == 30)
        #expect(MediaFetch.retryDelay(attempt: 4) == nil)
        #expect(MediaFetch.retryDelay(attempt: 0) == nil)
    }
}

struct AutoDownloadPolicyTests {
    private let image = Int64(Engine.autoDownloadImageLimit)
    private let media = Int64(Engine.autoDownloadLimit)

    @Test func withTheSettingOffNothingIsFetchedForAnyKind() {
        let kinds: [AttachmentKind?] = [.image, .video, .audio, .pdf, .text, .file, nil]
        for kind in kinds {
            for size in [nil, 1, image, media, 90_000_000] as [Int64?] {
                #expect(AutoDownloadPolicy.decide(kind: kind, size: size, setting: false) == .cachedOnly)
            }
        }
    }

    @Test func imagesAreCappedAtTheImageLimit() {
        #expect(AutoDownloadPolicy.decide(kind: .image, size: nil, setting: true) == .fetchNow(upTo: Engine.autoDownloadImageLimit))
        #expect(AutoDownloadPolicy.decide(kind: .image, size: image, setting: true) == .fetchNow(upTo: Engine.autoDownloadImageLimit))
        #expect(AutoDownloadPolicy.decide(kind: .image, size: image + 1, setting: true) == .hold)
        #expect(AutoDownloadPolicy.decide(kind: .image, size: 38_000_000, setting: true) == .hold)
    }

    @Test func videosAndVoiceMessagesAreCappedAtTheMediaLimit() {
        for kind in [AttachmentKind.video, .audio] {
            #expect(AutoDownloadPolicy.decide(kind: kind, size: nil, setting: true) == .fetchNow(upTo: Engine.autoDownloadLimit))
            #expect(AutoDownloadPolicy.decide(kind: kind, size: media, setting: true) == .fetchNow(upTo: Engine.autoDownloadLimit))
            #expect(AutoDownloadPolicy.decide(kind: kind, size: media + 1, setting: true) == .hold)
        }
    }

    @Test func filesAreNeverFetchedUnasked() {
        for kind in [AttachmentKind.pdf, .text, .file] {
            #expect(AutoDownloadPolicy.decide(kind: kind, size: 100, setting: true) == .cachedOnly)
        }
        #expect(AutoDownloadPolicy.decide(kind: nil, size: nil, setting: true) == .cachedOnly)
    }
}
