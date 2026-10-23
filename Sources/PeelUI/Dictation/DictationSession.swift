import Foundation

/// A finished recording, handed to a `Transcriber`. The file is the
/// receiver's to delete.
public struct DictationSession: Equatable, Sendable {
    public let id: UUID
    public let audioURL: URL
    public let duration: TimeInterval
    public let mode: DictationMode

    public init(id: UUID = UUID(), audioURL: URL, duration: TimeInterval, mode: DictationMode) {
        self.id = id
        self.audioURL = audioURL
        self.duration = duration
        self.mode = mode
    }
}

/// Turns a recording into text. Milestone 0 has only the stub; the real one
/// (milestone 1) is not part of this feature.
public protocol Transcriber: Sendable {
    func transcribe(audioFileURL: URL) async throws -> String
}

/// Canned text, for the demo.
public struct StubTranscriber: Transcriber {
    public static let text = "This is a stub transcription."
    private let result: String

    public init(result: String = StubTranscriber.text) { self.result = result }

    public func transcribe(audioFileURL: URL) async throws -> String { result }
}
