import Foundation
import Observation
import PeelCore

/// Where a video is on its way out, for the bar over the chat: compressed to
/// fit (`VideoCompressor`), then uploaded. Zero height when idle; `done`
/// goes by itself, `failed` stays until dismissed.
public enum TransferState: Equatable, Sendable {
    case idle
    case compressing(Double)
    case uploading(Double)
    case done
    case failed(String)

    /// The bar's words: "Compressing video for upload…", "Uploading…", the
    /// failure's reason.
    public var words: String? {
        switch self {
        case .idle: nil
        case .compressing: String(localized: "Compressing video for upload…", table: "Shared")
        case .uploading: String(localized: "Uploading…", table: "Shared")
        case .done: String(localized: "Sent", table: "Shared")
        case .failed(let reason): reason
        }
    }

    /// How far along the running phase is, 0...1; none when it has no length.
    public var fraction: Double? {
        switch self {
        case .compressing(let value), .uploading(let value): min(max(value, 0), 1)
        case .done: 1
        case .idle, .failed: nil
        }
    }
}

/// One video's compression, started when it enters a composer's tray. The
/// tray shows its `progress`; Send waits for `result` and the upload begins
/// when it is done.
@MainActor @Observable
public final class VideoJob {
    /// 0...1.
    public internal(set) var progress = 0.0
    /// Send took the file: it, not the tray, carries the result on.
    @ObservationIgnored var claimed = false
    @ObservationIgnored var result: Task<URL, any Error>?

    func cancel() { result?.cancel() }
}

extension AppModel {
    /// Compresses a video over the send limit into a temporary copy of Peel's.
    /// The file itself is never touched. When it is done the tray holds the
    /// copy in its place (unless Send already took it: `resolveVideos`).
    func compress(_ file: URL, in composer: ComposerID) {
        let job = VideoJob()
        videoJobs[file] = job
        if case .uploading = transfer {} else { setTransfer(.compressing(0)) }
        job.result = Task.detached(priority: .userInitiated) {
            let output = try VideoCompressor.outputURL(for: file)
            do {
                try await VideoCompressor.compress(file, to: output) { [weak self] fraction in
                    Task { @MainActor in
                        job.progress = fraction
                        self?.compressionProgressed(job)
                    }
                }
            } catch {
                IncomingFiles.discard(output)
                throw error
            }
            return output
        }
        Task { [weak self] in
            guard let result = job.result else { return }
            do {
                let output = try await result.value
                self?.compressed(file, as: output, in: composer, job: job)
            } catch {
                self?.compressionFailed(file, error, in: composer, job: job)
            }
        }
    }

    private func compressionProgressed(_ job: VideoJob) {
        if case .compressing = transfer { transfer = .compressing(job.progress) }
    }

    private func compressed(_ file: URL, as output: URL, in composer: ComposerID, job: VideoJob) {
        if videoJobs[file] === job { videoJobs[file] = nil }
        guard !job.claimed else { return }
        guard let index = pendingFiles[composer]?.firstIndex(of: file) else {
            // Taken out of the tray meanwhile.
            IncomingFiles.discard(output)
            return
        }
        pendingFiles[composer]?[index] = output
        compressedCopies.insert(output)
        // Peel's own copy of a picked video is done with; a file of the person's is never removed.
        release(file)
        if case .compressing = transfer, videoJobs.isEmpty { setTransfer(.idle) }
    }

    private func compressionFailed(_ file: URL, _ error: any Error, in composer: ComposerID, job: VideoJob) {
        if videoJobs[file] === job { videoJobs[file] = nil }
        guard !job.claimed else { return }
        if error is CancellationError {
            if case .compressing = transfer, videoJobs.isEmpty { setTransfer(.idle) }
            return
        }
        // It is still over the limit: it cannot stay in the tray.
        pendingFiles[composer]?.removeAll { $0 == file }
        release(file)
        let reason = PeelError.problem(error, couldNot: String(localized: "compress \(file.lastPathComponent)", table: "Shared"))
        setTransfer(.failed(reason))
        if let chat = composer.chat { conversationNotices[chat] = reason }
    }

    /// For Send: each file as it will go. A video still compressing is
    /// waited for (its upload starts as the compression ends); one that
    /// could not be compressed is in `failures`, said by the bar too.
    func resolveVideos(_ files: [URL]) async -> (files: [URL], compressed: Set<URL>, failures: [(file: URL, reason: String)]) {
        var out: [URL] = [], compressed: Set<URL> = [], failures: [(file: URL, reason: String)] = []
        // Every job is taken before the first wait, so none that finishes
        // meanwhile is handled as the tray's.
        let jobs = files.map { videoJobs[$0] }
        jobs.forEach { $0?.claimed = true }
        for (file, job) in zip(files, jobs) {
            guard let job, let result = job.result else {
                out.append(file)
                // Compressed while it sat in the tray: its upload is still the bar's.
                if compressedCopies.contains(file) { compressed.insert(file) }
                continue
            }
            do {
                let output = try await result.value
                release(file)
                out.append(output)
                compressed.insert(output)
                compressedCopies.insert(output)
            } catch {
                guard !(error is CancellationError) else { continue }
                let reason = PeelError.problem(error, couldNot: String(localized: "compress \(file.lastPathComponent)", table: "Shared"))
                failures.append((file, reason))
                release(file)
                setTransfer(.failed(reason))
            }
        }
        if !compressed.isEmpty { setTransfer(.uploading(0)) }
        return (out, compressed, failures)
    }

    /// The bar's uploading phase, from the engine's progress for the row.
    func uploadProgressed(bytes: Int64, total: Int64) {
        guard case .uploading = transfer, total > 0 else { return }
        transfer = .uploading(Double(bytes) / Double(total))
    }

    /// After the sends: done (and gone in a moment) when every compressed
    /// video is uploaded, else why not.
    func finishTransfer(
        of compressed: Set<URL>, results: [(file: URL, result: Result<Int64, any Error>)],
        refused: [(file: URL, reason: String)]
    ) {
        trackedUpload = nil
        guard !compressed.isEmpty else { return }
        for (file, result) in results where compressed.contains(file) {
            switch result {
            case .failure:
                setTransfer(.failed(refused.first { $0.file == file }?.reason ?? String(localized: "The video was not sent.", table: "Shared")))
                return
            case .success(let id):
                compressedCopies.remove(file)
                if (try? engine?.storage.message(id: id))?.uploadState != .done {
                    setTransfer(.failed(String(localized: "The video was not uploaded. Retry it from its message.", table: "Shared")))
                    return
                }
            }
        }
        setTransfer(.done)
    }

    /// Sets the bar's state; `done` clears itself after a moment.
    func setTransfer(_ state: TransferState) {
        transferDismissal?.cancel()
        transferDismissal = nil
        transfer = state
        if case .done = state {
            transferDismissal = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled, let self, case .done = self.transfer else { return }
                self.transfer = .idle
            }
        }
    }

    /// The bar's close, for a failure.
    public func dismissTransfer() {
        if case .compressing = transfer { return }
        if case .uploading = transfer { return }
        setTransfer(.idle)
    }

    func cancelVideoJob(for file: URL) {
        compressedCopies.remove(file)
        guard let job = videoJobs.removeValue(forKey: file) else { return }
        job.cancel()
        if case .compressing = transfer, videoJobs.isEmpty { setTransfer(.idle) }
    }

    /// The account closed: nothing keeps compressing for it.
    func cancelVideoJobs() {
        videoJobs.values.forEach { $0.cancel() }
        videoJobs = [:]
        compressedCopies = []
        trackedUpload = nil
        setTransfer(.idle)
    }

    /// For the tray: how far a file's compression is, or none when it is not
    /// being compressed.
    public func compression(of file: URL) -> VideoJob? { videoJobs[file] }
}
