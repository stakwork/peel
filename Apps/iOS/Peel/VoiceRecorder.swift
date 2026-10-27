import AVFoundation
import Observation
import PeelCore
import SwiftUI
import UIKit

/// Records a voice message while the mic is held: 16 kHz mono 16-bit WAV
/// (`VoiceMessage`), into a folder of Peel's (`IncomingFiles`) so the
/// model's send releases it. The rules (minimum length, slide to cancel,
/// the clock) are `VoiceRecorderState`'s and `VoiceMessage`'s, in PeelCore.
@MainActor @Observable
final class VoiceRecorder {
    private(set) var state = VoiceRecorderState()
    /// Set when the microphone is refused; the composer says so.
    var denied = false

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// The finger is still down; false by the time permission answers means nothing starts.
    @ObservationIgnored private var held = false
    @ObservationIgnored private var onLimit: ((URL) -> Void)?

    /// The mic was pressed. `limit` gets the file when the maximum length is reached.
    func begin(onLimit: @escaping (URL) -> Void) async {
        guard !held else { return }
        held = true
        self.onLimit = onLimit
        denied = false
        guard await Self.permission() else {
            held = false
            denied = true
            return
        }
        guard held else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let url = try IncomingFiles.newFolder().appendingPathComponent("voice.wav")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: VoiceMessage.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record() else { throw PeelError("the microphone is busy") }
            self.recorder = recorder
            file = url
            state.begin()
            Self.haptic(.medium)
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self, let recorder = self.recorder else { return }
                    if self.state.tick(elapsed: recorder.currentTime), let url = self.stop() {
                        self.onLimit?(url)
                        return
                    }
                }
            }
        } catch {
            held = false
            cleanUp()
        }
    }

    /// The finger moved.
    func drag(dx: Double, dy: Double) { state.drag(dx: dx, dy: dy) }

    /// The finger lifted: the file to send, or nil when it was slid away or too short.
    func end(dx: Double, dy: Double) -> URL? {
        held = false
        guard state.isRecording else { return nil }
        let outcome = state.finish(dx: dx, dy: dy)
        let url = stop()
        Self.haptic(outcome == .send ? .light : .rigid)
        guard outcome == .send, let url else {
            url.map(IncomingFiles.discard)
            return nil
        }
        return url
    }

    /// Stops without sending (the app left the front, say).
    func cancel() {
        held = false
        state.abort()
        stop().map(IncomingFiles.discard)
    }

    private func stop() -> URL? {
        ticker?.cancel()
        ticker = nil
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        defer { file = nil }
        return file
    }

    private func cleanUp() {
        state.abort()
        stop().map(IncomingFiles.discard)
    }

    private static func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    /// Asked the first time the mic is pressed (the system prompt shows
    /// once); a granted or refused answer comes back at once after that.
    private static func permission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: break
        }
        return await AVAudioApplication.requestRecordPermission()
    }
}

/// What the capsule shows while recording: a red dot, the elapsed time and
/// the way to cancel.
struct RecordingIndicator: View {
    let state: VoiceRecorderState

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Circle().fill(Theme.destructive).frame(width: 10, height: 10)
            Text(state.clock)
                .monospacedDigit()
                .foregroundStyle(Theme.text)
            Spacer(minLength: 0)
            Text(state.phase == .cancelling ? "Release to cancel" : "‹ Slide to cancel")
                .phoneFont(.secondary)
                .foregroundStyle(state.phase == .cancelling ? Theme.destructive : Theme.secondaryText)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: Theme.touchTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording, \(state.clock)")
    }
}

/// The mic: hold to record, release to send, slide away to cancel.
struct HoldToRecordButton: View {
    let recorder: VoiceRecorder
    /// Told the file when released to send (or at the maximum length).
    let send: (URL) -> Void

    @State private var pressed = false

    var body: some View {
        GlassSymbol(systemImage: "mic", label: "Record a voice message",
                    tint: recorder.state.isRecording ? Theme.destructive : Theme.secondaryText)
            .frame(width: Theme.touchTarget, height: Theme.touchTarget)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !pressed {
                            pressed = true
                            Task { await recorder.begin(onLimit: send) }
                        }
                        recorder.drag(dx: value.translation.width, dy: value.translation.height)
                    }
                    .onEnded { value in
                        pressed = false
                        if let url = recorder.end(dx: value.translation.width, dy: value.translation.height) {
                            send(url)
                        }
                    }
            )
            .accessibilityLabel("Record a voice message")
            .accessibilityHint("Hold to record, release to send")
            .accessibilityAddTraits(.isButton)
    }
}
