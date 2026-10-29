import AppKit
import AVFoundation
import Observation
import os
@preconcurrency import ScreenCaptureKit
import PeelAgent
import PeelCore
import PeelUI

/// Screen recording, v1 (docs/recording.md): a display, the microphone and
/// the camera bubble to an MP4 in Downloads, then its words from
/// Peel's strut as captions in the file. Owns
/// the glue; `ScreenRecorder`, `CameraBubblePanel`, `RecordingBarPanel` and
/// `RecordingMedia` do the work.
@MainActor @Observable
final class RecordingController {
    static let shared = RecordingController()

    enum Phase {
        case idle
        /// Asking for permissions, the picker open, the capture starting.
        case starting
        /// The screen picked, the camera bubble and the bar up: waiting for Record.
        case ready
        case recording
        /// Stopped, the file being finished.
        case stopping
    }

    /// A recording in the folder.
    struct Recording: Identifiable {
        let url: URL
        let created: Date
        let bytes: Int
        var id: URL { url }
        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    private(set) var phase: Phase = .idle
    /// Seconds recorded, while recording.
    private(set) var elapsed: TimeInterval = 0
    /// How long until the recording reaches `longest`, once that is under a
    /// minute (`warning`): shown on the bar.
    private(set) var timeLeft: TimeInterval?
    /// The mic went quiet: the one now recorded, for a moment, or that
    /// none is heard. Shown on the bar.
    private(set) var micNote: String?
    /// What last went wrong, or why the last recording stopped on its own.
    private(set) var problem: String?
    /// What is in the folder, newest first.
    private(set) var recordings: [Recording] = []
    /// Where a recording's captions are, since Peel opened: being made,
    /// in, or why they couldn't be.
    private(set) var captions: [URL: String] = [:]

    /// The camera bubble is in the next recording.
    /// The longest a recording runs, in minutes, before it stops itself:
    /// one of `lengths`. Only so a forgotten one cannot fill the disk; how
    /// it is sent is the person's, Peel sending what fits (`sendLimit`).
    var longest: Int {
        didSet { UserDefaults.standard.set(longest, forKey: Self.longestKey) }
    }
    var cameraOn: Bool {
        didSet { UserDefaults.standard.set(cameraOn, forKey: Self.cameraKey) }
    }

    @ObservationIgnored private var recorder: ScreenRecorder?
    /// What Record records: the display picked, and its screen.
    @ObservationIgnored private var picked: (filter: SCContentFilter, screen: NSScreen?)?
    @ObservationIgnored private var discarding = false
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var micChangedAt: ContinuousClock.Instant?
    @ObservationIgnored private lazy var bubble = CameraBubblePanel()
    @ObservationIgnored private lazy var bar = RecordingBarPanel(controller: self)
    /// Why a recording stopped on its own, where the bar was: the dictation HUD's message.
    @ObservationIgnored private lazy var notice = DictationHUDPanel()
    @ObservationIgnored private let log = Logger(subsystem: "dev.peel.mac", category: "recording")

    private static let cameraKey = "recordingCamera"
    private static let longestKey = "recordingLongest"
    /// The choices for `longest`, in minutes, and the one it starts on.
    static let lengths = [5, 15, 30, 60]
    private static let defaultLongest = 30
    /// The most a recording can be to send in a chat: what the hosted memes
    /// server takes (Tom, 2026-10-29), short of Peel's own attachment limit.
    static let sendLimit = 25_000_000
    /// How near `longest` the bar counts down.
    private static let warning: TimeInterval = 60
    /// This long with nothing at all from the mic, not even its hiss, it is deaf.
    private static let deaf: TimeInterval = 2
    /// How long the bar says which mic the recording moved to.
    private static let micNoteShown: Duration = .seconds(5)
    /// The longest captions wait for strut's fixer to load, over a whole
    /// recording: past strut's own 30 s of leaving a slow one out.
    private static let fixerWait: Duration = .seconds(45)

    private init() {
        cameraOn = UserDefaults.standard.object(forKey: Self.cameraKey) as? Bool ?? true
        let saved = UserDefaults.standard.integer(forKey: Self.longestKey)
        longest = Self.lengths.contains(saved) ? saved : Self.defaultLongest
    }

    /// Downloads, where the recordings go.
    static var folder: URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    // MARK: Recording

    /// Asks for what it needs and opens macOS's picker for a display; once
    /// one is picked, the camera bubble and the bar wait there for Record.
    func start() {
        guard phase == .idle, !Offscreen.refuses("screen recording") else { return }
        phase = .starting
        problem = nil
        Task {
            guard await Self.allowed(.audio, settings: "Privacy_Microphone") else {
                return fail("Peel can't use the microphone: turn it on in System Settings, then record again.")
            }
            let camera = cameraOn ? await Self.allowed(.video, settings: "Privacy_Camera") : false
            if cameraOn, !camera { problem = "Recording without the camera: turn it on for Peel in System Settings." }
            // Peel's own windows stay in the picture the picker hands back:
            // the bubble, and Peel itself when it is what you are showing.
            guard let filter = await ScreenShare.pick(.display, includePeel: true) else {
                phase = .idle
                return
            }
            let screen = ScreenShare.screen(of: filter) ?? NSScreen.main
            if camera, !bubble.show(on: screen) { problem = "Recording without the camera: none was found." }
            picked = (filter, screen)
            phase = .ready
            bar.show(on: screen)
        }
    }

    /// Starts recording the picked display, the bubble already in place.
    func record() {
        guard phase == .ready, let picked else { return }
        phase = .starting
        elapsed = 0
        timeLeft = nil
        micNote = nil
        Task {
            do {
                let started = try await ScreenRecorder.start(picked.filter, micChanged: { name in self.micChanged(to: name) }) { url, error in
                    self.ended(url, error)
                }
                // Ended already, as it started.
                guard phase == .starting else { return }
                recorder = started
            } catch {
                putAway()
                log.error("recording did not start: \(String(describing: error), privacy: .public)")
                return fail("The recording couldn't start.")
            }
            phase = .recording
            bar.show(on: picked.screen)
            let ticker = Timer(timeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { self.tick() }
            }
            // Common modes: it keeps time while the bubble is dragged or a menu is open.
            RunLoop.main.add(ticker, forMode: .common)
            self.ticker = ticker
        }
    }

    /// Ends the recording and keeps it.
    func stop() {
        guard phase == .recording, let recorder else { return }
        phase = .stopping
        putAway()
        Task { await recorder.stop() }
    }

    /// Ends the recording and throws it away; before Record, puts the
    /// bubble and the bar away.
    func discard() {
        switch phase {
        case .ready:
            putAway()
            phase = .idle
        case .recording:
            discarding = true
            stop()
        case .idle, .starting, .stopping:
            return
        }
    }

    /// The bar, the bubble and the clock, once the recording is over.
    private func putAway() {
        picked = nil
        ticker?.invalidate()
        ticker = nil
        bar.orderOut(nil)
        bubble.hide()
    }

    private func tick() {
        guard let recorder else { return }
        elapsed = recorder.duration
        let left = TimeInterval(longest * 60) - elapsed
        if left <= 0 {
            problem = "The recording stopped at \(longest) minutes, your recording limit."
            stop()
            notice.show(.message("Stopped at \(longest) minutes. Saved to Downloads"))
            return
        }
        let before = (timeLeft == nil, micNote)
        timeLeft = left <= Self.warning ? left : nil
        if recorder.micSilence >= Self.deaf {
            // Gone deaf (a headset's mic dropped): the default input again.
            micNote = "No sound from your mic"
            recorder.reopenMic()
        } else if let changed = micChangedAt, changed.duration(to: .now) < Self.micNoteShown {
            // The note `micChanged` set stays a moment.
        } else if micNote != nil {
            micNote = nil
        }
        if before != (timeLeft == nil, micNote) { bar.refit() }
    }

    /// The recording moved to another mic, macOS's default input now.
    private func micChanged(to name: String) {
        guard phase == .recording else { return }
        micChangedAt = .now
        micNote = "Now using \(name)"
        bar.refit()
    }

    /// The file at `url` is finished, or the recording failed (after `stop`,
    /// or macOS ending the capture, or as it started).
    private func ended(_ url: URL, _ error: (any Error)?) {
        // macOS ended it, or it failed as Record started: nothing to stop.
        if phase != .idle { putAway() }
        recorder = nil
        phase = .idle
        let discarded = discarding
        discarding = false
        if discarded {
            try? FileManager.default.removeItem(at: url)
            return
        }
        Task {
            // A failure that still left a whole file (the stop's error came
            // first) keeps it.
            if let error {
                log.error("recording failed: \(String(describing: error), privacy: .public)")
                guard (try? await AVURLAsset(url: url).load(.isPlayable)) == true else {
                    try? FileManager.default.removeItem(at: url)
                    problem = "The recording couldn't be saved."
                    return
                }
            }
            let name = RecordingCaptions.fileName(at: .now)
            do {
                let kept = try keep(url, as: name)
                refresh()
                await addCaptions(to: kept)
            } catch {
                // Never lost for want of Downloads: saved where the person picks.
                log.error("recording not kept in Downloads: \(String(describing: error), privacy: .public)")
                guard let target = FilePanels().saveLocation(named: name + ".mp4"), (try? FileManager.default.moveItem(at: url, to: target)) != nil else {
                    try? FileManager.default.removeItem(at: url)
                    problem = "The recording couldn't be saved."
                    return
                }
                problem = "Saved where you chose, not in Downloads, so it isn't listed here."
                await addCaptions(to: target)
            }
        }
    }

    /// Moves the finished file into the folder under `name`, numbered if
    /// that is taken (the hour a clock goes back).
    private func keep(_ url: URL, as name: String) throws -> URL {
        guard let folder = Self.folder else { throw CocoaError(.fileNoSuchFile) }
        for number in 1...99 {
            let target = folder.appendingPathComponent(number == 1 ? name : "\(name) \(number)").appendingPathExtension("mp4")
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// What a quit or crash mid-recording or mid-captions left in the temp
    /// folder: the screen and the microphone, never to be used. At launch.
    static func sweepLeftovers() {
        let temp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
        for name in names where name.hasPrefix("peel-recording-") {
            try? FileManager.default.removeItem(at: temp.appendingPathComponent(name))
        }
    }

    // MARK: Captions

    /// The recording's words from Peel's strut, as captions in the file.
    /// Without them the video stays as it is.
    private func addCaptions(to video: URL) async {
        captions[video] = "Adding captions…"
        let temp = FileManager.default.temporaryDirectory
        let wav = temp.appendingPathComponent("peel-recording-\(UUID().uuidString).wav")
        let pieces = temp.appendingPathComponent("peel-recording-\(UUID().uuidString)")
        let captioned = temp.appendingPathComponent("peel-recording-\(UUID().uuidString).mp4")
        defer {
            for leftover in [wav, pieces, captioned] { try? FileManager.default.removeItem(at: leftover) }
        }
        do {
            let duration = try await RecordingMedia.extractAudio(from: video, to: wav)
            try FileManager.default.createDirectory(at: pieces, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            // A dictation's length at a time, cut at pauses, so strut's fixer has
            // time to apply the vocabulary; each piece's times moved to the recording's.
            let dictation = DictationController.shared
            var words: [TimedWord] = []
            var waited = Duration.zero
            for piece in try await RecordingMedia.pieces(of: wav, in: pieces) {
                var reply = try await dictation.speech.words(piece.url)
                // A fixer loading misses its time, and strut leaves it out for a
                // while after: the piece again once it is up, as long as is fair.
                while !reply.fixed, !reply.words.isEmpty, dictation.models.hasActiveFixer, waited < Self.fixerWait {
                    try await Task.sleep(for: .seconds(3))
                    waited += .seconds(3)
                    reply = try await dictation.speech.words(piece.url)
                }
                words += reply.words.map { TimedWord(text: $0.text, start: $0.start + piece.start) }
            }
            guard !words.isEmpty else {
                captions[video] = "No speech was heard"
                return
            }
            try await RecordingMedia.addCaptions(RecordingCaptions.cues(from: words, duration: duration), to: video, writingTo: captioned)
            _ = try FileManager.default.replaceItemAt(video, withItemAt: captioned)
            captions[video] = "Captioned"
        } catch let failure as StrutSpeech.Failure {
            captions[video] = "No captions: \(failure)"
        } catch {
            log.error("captions failed: \(String(describing: error), privacy: .public)")
            captions[video] = "No captions: they couldn't be made"
        }
        refresh()
    }

    // MARK: The folder

    /// Reads what is in the folder.
    func refresh() {
        guard let folder = Self.folder else { return }
        // Names only, then Peel's own by their name: Downloads can hold thousands.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        recordings = names.filter { $0.hasPrefix("Peel Recording ") && RecordingCaptions.isRecordingName($0) }.compactMap { name in
            let url = folder.appendingPathComponent(name)
            // A plain file only: a link planted under a recording's name is
            // not one, and dragged into a chat would send what it points to.
            guard let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return Recording(url: url, created: values.creationDate ?? .distantPast, bytes: values.fileSize ?? 0)
        }
        .sorted { $0.created > $1.created }
    }

    func showInFinder(_ recording: Recording) {
        FilePanels().reveal(recording.url)
    }

    // MARK: Helpers

    private func fail(_ why: String) {
        phase = .idle
        problem = why
    }

    /// Whether `media` may be used, asking the first time; refused before,
    /// its pane of System Settings opens, as dictation's does.
    private static func allowed(_ media: AVMediaType, settings pane: String) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
        default:
            DictationController.shared.permissions.open(pane)
            return false
        }
    }
}
