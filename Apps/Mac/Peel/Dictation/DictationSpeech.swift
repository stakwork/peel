import Foundation
import Observation
import PeelAgent
import PeelUI

/// Dictation's speech-to-text on Peel's own strut (`StrutSpeech`): its
/// model, fetched once per account, and each recording turned into text.
/// The strut is the open account's, told here whenever it starts or stops
/// (`AppModel.strutChanged`); a home server's is never used.
@MainActor @Observable
final class DictationSpeech {
    enum ModelState: Equatable {
        /// Peel's strut has not started (it starts with the account's agent).
        case waiting
        case checking
        case downloading
        case installed
        case failed(String)
    }

    private(set) var model: ModelState = .waiting
    /// Told when a recording has to wait for the model's download.
    @ObservationIgnored var onDownloadWait: () -> Void = {}
    @ObservationIgnored private var server: MemoryServer?
    @ObservationIgnored private var download: Task<Void, any Error>?
    /// Recordings waiting on the model, to be told if it has to be downloaded.
    @ObservationIgnored private var waiting = 0

    /// How long a recording waits for the strut, if it is still starting.
    private static let strutWait: Duration = .seconds(10)

    /// Peel's strut started, stopped or was replaced (another account, a
    /// restart): the model is that strut's to check, its cache being the account's.
    func use(_ new: MemoryServer?) {
        guard new != server else { return }
        server = new
        download?.cancel()
        download = nil
        model = new == nil ? .waiting : .checking
    }

    /// Checks for the model and fetches it if it is missing, so it is there
    /// before the first recording: once dictation is on and the strut is up.
    func prepare() {
        guard server != nil, model == .checking, download == nil else { return }
        Task { try? await ensureModel() }
    }

    /// The model, there or fetched now; one check and download at a time, shared.
    func ensureModel() async throws {
        if model == .installed { return }
        if let download { return try await download.value }
        guard let server else { throw StrutSpeech.Failure.unreachable }
        let speech = StrutSpeech(server: server)
        let task = Task { [weak self] in
            guard let self else { return }
            self.model = .checking
            do {
                if try await !speech.modelInstalled() {
                    self.model = .downloading
                    if self.waiting > 0 { self.onDownloadWait() }
                    try await speech.downloadModel()
                }
                // Not if another strut took this one's place meanwhile.
                if self.server == server { self.model = .installed }
            } catch {
                if self.server == server { self.model = .failed(String(describing: error)) }
                throw error
            }
        }
        download = task
        defer { if download == task { download = nil } }
        try await task.value
    }

    /// The recording's text.
    func transcribe(_ wav: URL) async throws -> String {
        let server = try await strut()
        waiting += 1
        defer { waiting -= 1 }
        if model == .downloading { onDownloadWait() }
        try await ensureModel()
        return try await StrutSpeech(server: server).transcribe(wavAt: wav)
    }

    /// Peel's strut, waiting a little if it is still starting.
    private func strut() async throws -> MemoryServer {
        let clock = ContinuousClock()
        let until = clock.now + Self.strutWait
        while true {
            if let server { return server }
            guard clock.now < until else { throw StrutSpeech.Failure.unreachable }
            try await Task.sleep(for: .milliseconds(250))
        }
    }
}

/// The `Transcriber` dictation hands its recordings to: Peel's strut.
struct StrutTranscriber: Transcriber {
    let speech: DictationSpeech

    func transcribe(audioFileURL: URL) async throws -> String {
        try await speech.transcribe(audioFileURL)
    }
}
