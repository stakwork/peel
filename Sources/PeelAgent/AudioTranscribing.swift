import Foundation
#if canImport(Speech)
import Speech
#endif

/// Speech to text for a recording, on this Mac: a seam so the tests use a
/// fake and a platform with no recognizer says so. Never over the network.
public protocol AudioTranscribing: Sendable {
    /// The words said in `file`, in `locale`. Throws
    /// `AttachmentText.Failure.cannotTranscribe` when this device cannot
    /// recognise that language offline or is not allowed to.
    func transcribe(_ file: URL, locale: Locale) async throws -> String
}

/// Apple's recognizer, required to run on the device
/// (`requiresOnDeviceRecognition`), as voice mode's listener does
/// (`Apps/Shared/Voice/VoiceListener.swift`).
public struct SystemTranscriber: AudioTranscribing {
    public init() {}

    public func transcribe(_ file: URL, locale: Locale) async throws -> String {
        #if canImport(Speech)
        let language = locale.identifier
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw AttachmentText.Failure.cannotTranscribe(locale: language)
        }
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard status == .authorized else { throw AttachmentText.Failure.cannotTranscribe(locale: language) }
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        let finish = Once()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
                finish.task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        if finish.first() { continuation.resume(returning: result.bestTranscription.formattedString) }
                    } else if let error {
                        guard finish.first() else { return }
                        // Silence is not a failure (the recognizer's "no speech detected", 1110): an empty transcript.
                        if (error as NSError).code == 1110 { continuation.resume(returning: "") } else {
                            continuation.resume(throwing: AttachmentText.Failure.failed(PeelErrorText.words(error)))
                        }
                    }
                }
            }
        } onCancel: { finish.task?.cancel() }
        #else
        throw AttachmentText.Failure.cannotTranscribe(locale: locale.identifier)
        #endif
    }

    #if canImport(Speech)
    /// A recognition's one answer: its callback may come more than once.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var answered = false
        var task: SFSpeechRecognitionTask?

        func first() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            defer { answered = true }
            return !answered
        }
    }
    #endif
}

/// An error's words for the model, without anything it might carry.
enum PeelErrorText {
    static func words(_ error: any Error) -> String {
        "the recording could not be transcribed (\((error as NSError).domain) \((error as NSError).code))"
    }
}
