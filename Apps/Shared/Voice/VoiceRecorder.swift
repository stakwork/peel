import AVFoundation
import Observation
import PeelCore
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Records a voice message while the mic is held: 16 kHz mono 16-bit WAV
/// (`VoiceMessage`), into a folder of Peel's (`IncomingFiles`) so the
/// model's send releases it. The rules (minimum length, slide to cancel,
/// the clock) are `VoiceRecorderState`'s and `VoiceMessage`'s, in PeelCore.
/// Shared by the phone and the Mac; they differ in the permission, the
/// audio session (the phone's), the haptic and Escape (the Mac's).
@MainActor @Observable
final class VoiceRecorder {
    private(set) var state = VoiceRecorderState()
    /// Set when the microphone is refused; the composer says so.
    var denied = false

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// The finger or button is still down; false by the time permission answers means nothing starts.
    @ObservationIgnored private var held = false
    @ObservationIgnored private var onLimit: ((URL) -> Void)?
    #if os(macOS)
    @ObservationIgnored private var escapeMonitor: Any?
    #endif

    /// The mic was pressed. `onLimit` gets the file when the maximum length is reached.
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
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            #endif
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
            Self.haptic(start: true)
            watchEscape()
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

    /// The finger or pointer moved.
    func drag(dx: Double, dy: Double) { state.drag(dx: dx, dy: dy) }

    /// Released: the file to send, or nil when it was slid away or too short.
    func end(dx: Double, dy: Double) -> URL? {
        held = false
        guard state.isRecording else { return nil }
        let outcome = state.finish(dx: dx, dy: dy)
        let url = stop()
        Self.haptic(start: false, sent: outcome == .send)
        guard outcome == .send, let url else {
            if let url { IncomingFiles.discard(url) }
            return nil
        }
        return url
    }

    /// Stops without sending (the app left the front, Escape).
    func cancel() {
        held = false
        state.abort()
        if let url = stop() { IncomingFiles.discard(url) }
    }

    private func stop() -> URL? {
        ticker?.cancel()
        ticker = nil
        recorder?.stop()
        recorder = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #else
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        #endif
        defer { file = nil }
        return file
    }

    private func cleanUp() {
        state.abort()
        if let url = stop() { IncomingFiles.discard(url) }
    }

    /// Escape cancels a recording on the Mac, wherever the keyboard focus is.
    private func watchEscape() {
        #if os(macOS)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.cancel() }
            return nil
        }
        #endif
    }

    /// Asked the first time the mic is pressed (the system prompt shows
    /// once); a granted or refused answer comes back at once after that.
    private static func permission() async -> Bool {
        #if os(iOS)
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: break
        }
        return await AVAudioApplication.requestRecordPermission()
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
        #endif
    }

    private static func haptic(start: Bool, sent: Bool = true) {
        #if os(iOS)
        let style: UIImpactFeedbackGenerator.FeedbackStyle = start ? .medium : (sent ? .light : .rigid)
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        #else
        NSHapticFeedbackManager.defaultPerformer.perform(start || sent ? .generic : .levelChange, performanceTime: .now)
        #endif
    }

    #if os(macOS)
    /// System Settings at the microphone's privacy list, for a refusal.
    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
    #endif
}

/// Hold to record, release to send, move away to cancel: the gesture of
/// the phone's and the Mac's mic, on whatever view is the button.
struct HoldToRecord: ViewModifier {
    let recorder: VoiceRecorder
    /// Told the file when released to send (or at the maximum length).
    let send: (URL) -> Void

    @State private var pressed = false

    func body(content: Content) -> some View {
        content.gesture(
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
    }
}

extension View {
    func holdToRecord(_ recorder: VoiceRecorder, send: @escaping (URL) -> Void) -> some View {
        modifier(HoldToRecord(recorder: recorder, send: send))
    }
}

/// What the composer shows while recording: a red dot, the elapsed time
/// and the way to cancel.
struct VoiceRecordingIndicator: View {
    let state: VoiceRecorderState

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Circle().fill(Theme.destructive).frame(width: 10, height: 10)
            Text(state.clock)
                .monospacedDigit()
                .foregroundStyle(Theme.text)
            Spacer(minLength: 0)
            Text(state.phase == .cancelling ? "Release to cancel" : Self.hint)
                .voiceNote()
                .foregroundStyle(state.phase == .cancelling ? Theme.destructive : Theme.secondaryText)
        }
        .padding(.horizontal, VoiceStyle.indicatorInset)
        .frame(minHeight: VoiceStyle.target)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording, \(state.clock)")
    }

    private static var hint: String {
        #if os(macOS)
        "Drag away or press Esc to cancel"
        #else
        "‹ Slide to cancel"
        #endif
    }
}
