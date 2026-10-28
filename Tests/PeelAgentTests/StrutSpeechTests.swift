import Foundation
import Testing
import PeelCore
@testable import PeelAgent
@testable import PeelTestSupport

/// Dictation's speech-to-text calls to strut (`StrutSpeech`), against
/// replies shaped as strut's `plans/native-dictation-client.md` documents them.
struct StrutSpeechTests {
    private func speech(_ stub: HTTPStub) throws -> StrutSpeech {
        StrutSpeech(server: try #require(MemoryServer(base: URL(string: "http://127.0.0.1:\(stub.port)")!, key: "k")))
    }

    /// A recording on disk, as dictation hands it over.
    private func wav(_ bytes: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID().uuidString).wav")
        try Data(bytes.utf8).write(to: url)
        return url
    }

    @Test func aRecordingGoesAsAWAVWithTheKeyAndComesBackAsText() async throws {
        let stub = try await HTTPStub { _ in
            #"{"text":" Ask Jamie about the Stakwork canvas. ","heard":"Ask Jamie about the stack work canvas.","segments":[],"model":"zipformer-en-kroko","fixer":"qwen3-1.7b-q4"}"#
        }
        defer { stub.stop() }
        let file = try wav("RIFF-wav-bytes")
        defer { try? FileManager.default.removeItem(at: file) }
        let text = try await speech(stub).transcribe(wavAt: file)
        // Strut applied the vocabulary; what it heard comes too.
        #expect(text.text == "Ask Jamie about the Stakwork canvas.")
        #expect(text.heard == "Ask Jamie about the stack work canvas.")
        let request = try #require(stub.requests.first)
        #expect(request.hasPrefix("POST /audio/transcribe "))
        #expect(request.contains("Authorization: Bearer k"))
        #expect(request.contains("Content-Type: audio/wav"))
        #expect(request.hasSuffix("RIFF-wav-bytes"))
    }

    @Test func aScreenRecordingsWordsComeBackWithTheirTimes() async throws {
        let stub = try await HTTPStub { _ in
            #"{"text":"Hello there. Next","segments":[{"text":"Hello there.","words":[{"text":"Hello","start":0.42},{"text":"there.","start":0.8}]},{"text":"Next","words":[{"text":"Next","start":4},{"start":5}]}]}"#
        }
        defer { stub.stop() }
        let file = try wav("RIFF-wav-bytes")
        defer { try? FileManager.default.removeItem(at: file) }
        let words = try await speech(stub).words(wavAt: file)
        // A word without its text is left out.
        #expect(words.map(\.text) == ["Hello", "there.", "Next"])
        #expect(words.map(\.start) == [0.42, 0.8, 4])
        #expect(try #require(stub.requests.first).hasPrefix("POST /audio/transcribe "))
    }

    @Test(arguments: [
        // A strut built without the speech engine.
        (501, #"{"error":"stt not available"}"#, StrutSpeech.Failure.noEngine),
        (401, #"{"error":"unauthorized"}"#, .keyRefused),
        (400, #"{"error":"not a WAV"}"#, .refused("not a WAV")),
    ])
    func refusalsSayWhy(status: Int, body: String, failure: StrutSpeech.Failure) async throws {
        let stub = try await HTTPStub(status: status) { _ in body }
        defer { stub.stop() }
        let file = try wav("RIFF")
        defer { try? FileManager.default.removeItem(at: file) }
        await #expect(throws: failure) { try await speech(stub).transcribe(wavAt: file) }
    }

    @Test func theModelIsInstalledOnlyWhenStrutSaysSo() async throws {
        let models = #"""
            {"available":true,"models":[
              {"id":"zipformer-en-kroko","installed":%@},
              {"id":"nemo-fast-conformer-en-80ms","installed":true}]}
            """#
        for installed in [true, false] {
            let stub = try await HTTPStub { _ in String(format: models, installed ? "true" : "false") }
            defer { stub.stop() }
            #expect(try await speech(stub).modelInstalled() == installed)
        }
        let none = try await HTTPStub { _ in #"{"available":false,"models":[]}"# }
        defer { none.stop() }
        await #expect(throws: StrutSpeech.Failure.noEngine) { try await speech(none).modelInstalled() }
    }

    @Test func theDownloadEndsOnDoneOrSaysWhyNot() async throws {
        let done = try await HTTPStub(contentType: "text/event-stream") { _, _ in
            "event: progress\ndata: {\"phase\":\"download\",\"received\":1,\"total\":2}\n\nevent: progress\ndata: {\"phase\":\"done\"}\n\n"
        }
        defer { done.stop() }
        try await speech(done).downloadModel()
        #expect(try #require(done.requests.first).hasPrefix("POST /audio/models/zipformer-en-kroko/download "))

        let failed = try await HTTPStub(contentType: "text/event-stream") { _, _ in
            "event: progress\ndata: {\"phase\":\"download\"}\n\nevent: error\ndata: {\"error\":\"disk full\"}\n\n"
        }
        defer { failed.stop() }
        await #expect(throws: StrutSpeech.Failure.modelUnavailable("disk full")) { try await speech(failed).downloadModel() }
    }
}
