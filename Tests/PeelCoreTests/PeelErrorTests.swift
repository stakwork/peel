import Foundation
import GRDB
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

    // MARK: - readable

    @Test func aURLErrorNeverNamesTheAddress() {
        let link = URL(string: "https://secret.example/invite?code=abc")!
        let info: [String: Any] = [
            NSURLErrorFailingURLErrorKey: link, NSURLErrorFailingURLStringErrorKey: link.absoluteString,
        ]
        for code: URLError.Code in [.timedOut, .serverCertificateUntrusted, .cannotFindHost, .resourceUnavailable] {
            let words = PeelError.readable(URLError(code, userInfo: info))
            #expect(!words.contains("secret.example") && !words.contains("code=abc"), "\(code.rawValue): \(words)")
        }
        // A description that names the host, as a certificate error's does.
        let named = URLError(.resourceUnavailable, userInfo: info.merging(
            [NSLocalizedDescriptionKey: "The server “secret.example” is not available."]) { $1 })
        #expect(PeelError.readable(named) == "something went wrong (NSURLErrorDomain error -1008)")
    }

    @Test func anUnmappedNSErrorNeverShowsItsUserInfo() {
        let error = NSError(domain: "Example", code: 7, userInfo: ["token": "hunter2", "server": "https://x.example"])
        let words = PeelError.readable(error)
        #expect(!words.contains("hunter2") && !words.contains("x.example") && !words.contains("UserInfo"))
        #expect(words.contains("Example error 7"))
        let described = NSError(domain: "WebKitErrorDomain", code: 102, userInfo: [
            NSLocalizedDescriptionKey: "Frame load interrupted", "WKJavaScriptExceptionSourceURL": "https://x.example",
        ])
        #expect(PeelError.readable(described) == "Frame load interrupted")
        let linked = NSError(domain: "Example", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open https://x.example/a"])
        #expect(PeelError.readable(linked) == "something went wrong (Example error 1)")
    }

    @Test func commonErrorsReadAsSentences() {
        let cases: [(any Error, String)] = [
            (URLError(.timedOut), "The server took too long to answer."),
            (URLError(.notConnectedToInternet), "Not connected to the internet."),
            (URLError(.cannotFindHost), "The server's address could not be found."),
            (URLError(.cannotConnectToHost), "The server could not be reached."),
            (URLError(.serverCertificateUntrusted), "A secure connection to the server could not be made."),
            (CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: "/Users/someone/a.txt"]), "The file was not found."),
            (CocoaError(.fileWriteNoPermission), "Peel is not allowed to use the file."),
            (CocoaError(.fileWriteOutOfSpace), "The disk is full."),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)), "The file was not found."),
            (POSIXError(.ECONNREFUSED), "The server could not be reached."),
            (DatabaseError(resultCode: .SQLITE_FULL, message: "disk full", sql: "INSERT INTO message …"), "The disk is full."),
            (DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad")), "The data could not be read."),
            (CancellationError(), "It was cancelled."),
        ]
        for (error, sentence) in cases {
            #expect(PeelError.problem(error) == sentence)
        }
    }

    @Test func peelsOwnWordsStay() {
        #expect(PeelError.readable(PeelError("photo.jpg is too large")) == "photo.jpg is too large")
        #expect(PeelError.readable(Engine.Failure.notConnected) == Engine.Failure.notConnected.description)
    }
}
