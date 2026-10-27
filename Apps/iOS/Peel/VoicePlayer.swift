import AVFoundation
import Observation
import PeelCore
import PeelUI
import SwiftUI

/// Plays one voice message from its decrypted file in the cache. One plays
/// at a time (`current`). Read by container (`MediaInfo.asset`), as cached
/// files have no extension.
@MainActor @Observable
final class VoicePlayer {
    private static weak var current: VoicePlayer?

    private(set) var isPlaying = false
    private(set) var time: TimeInterval = 0
    private(set) var duration: TimeInterval?
    /// The file is read and its length known.
    private(set) var isLoaded = false
    /// AVFoundation cannot play it (ogg, say).
    private(set) var isUnplayable = false

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var ended: NSObjectProtocol?
    @ObservationIgnored private var loaded: URL?

    func load(_ file: URL) async {
        guard loaded != file else { return }
        stop()
        loaded = file
        isLoaded = false
        isUnplayable = false
        let asset = MediaInfo.asset(file)
        let playable = (try? await asset.load(.isPlayable)) ?? false
        var length = (try? await asset.load(.duration)).flatMap { $0.isNumeric && $0.seconds > 0 ? $0.seconds : nil }
        if length == nil, let head = try? Data(contentsOf: file, options: .mappedIfSafe).prefix(4096) {
            // A WAV from a recorder that never fixed its header: the header's own reckoning.
            length = WavHeader(Data(head))?.duration
        }
        guard loaded == file else { return }
        guard playable || length != nil else {
            isUnplayable = true
            return
        }
        duration = length
        isLoaded = true
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        self.player = player
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] now in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying, now.isNumeric else { return }
                self.time = now.seconds
            }
        }
        ended = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.time = 0
                self.player?.seek(to: .zero)
            }
        }
    }

    func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            Self.current?.pause()
            Self.current = self
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
            isPlaying = true
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func seek(to seconds: TimeInterval) {
        let target = max(0, min(seconds, duration ?? seconds))
        time = target
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        if let ended { NotificationCenter.default.removeObserver(ended) }
        observer = nil
        ended = nil
        player = nil
        isPlaying = false
        isLoaded = false
        loaded = nil
        time = 0
    }
}

/// A voice message in a row: play or pause, a bar to drag or tap to seek,
/// and "current / total".
struct VoiceBubble: View {
    @Environment(AppModel.self) private var model
    let message: Message

    @State private var player = VoicePlayer()

    var body: some View {
        let handle = message.id.map(model.attachment)
        let file = handle?.file
        let state = VoiceMessage.rowState(
            uploading: message.uploadState == .pending, hasFile: file != nil,
            downloadFailed: handle?.failureReason != nil, loaded: player.isLoaded, unplayable: player.isUnplayable
        )
        let ready = state == .ready
        let fraction = VoiceMessage.fraction(current: player.time, total: player.duration)
        PhoneCard {
            HStack(spacing: Theme.Space.md) {
                Button { player.toggle() } label: {
                    Group {
                        if state == .loading || state == .uploading {
                            ProgressView().controlSize(.small).tint(Theme.buttonText)
                        } else {
                            Image(systemName: state == .failed ? "exclamationmark.triangle" : player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 16))
                        }
                    }
                        .foregroundStyle(Theme.buttonText)
                        .frame(width: 36, height: 36)
                        .background(Theme.button.opacity(ready ? 1 : 0.4), in: Circle())
                        .frame(width: Theme.touchTarget, height: Theme.touchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!ready)
                .accessibilityLabel(switch state {
                case .ready: player.isPlaying ? "Pause" : "Play"
                case .failed: "Can't play"
                default: "Loading"
                })
                VStack(alignment: .leading, spacing: 4) {
                    SeekBar(fraction: fraction, enabled: ready && (player.duration ?? 0) > 0) { x, width in
                        player.seek(to: VoiceMessage.seekTime(x: x, width: width, total: player.duration ?? 0))
                    }
                    Text(switch state {
                    case .ready: VoiceMessage.timeLabel(current: player.time, total: player.duration)
                    case .uploading: "Uploading…"
                    case .loading: "Loading…"
                    case .failed: "Can't play this audio"
                    })
                        .phoneFont(.time)
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, 4)
        }
        .frame(maxWidth: 280, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voice message")
        .task(id: file) {
            if let file {
                await player.load(file)
            } else if handle?.failureReason == nil {
                await model.autoDownload(message)
            }
        }
        .onDisappear { player.stop() }
    }
}

/// A thin bar that fills with `fraction`; a tap or drag on it seeks.
private struct SeekBar: View {
    let fraction: Double
    let enabled: Bool
    let seek: (_ x: Double, _ width: Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.divider)
                Capsule().fill(Theme.accent).frame(width: proxy.size.width * fraction)
                Circle().fill(Theme.accent).frame(width: 10, height: 10)
                    .offset(x: max(0, proxy.size.width * fraction - 5))
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    if enabled { seek(value.location.x, proxy.size.width) }
                }
            )
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(Int(fraction * 100)) percent")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.1 : -0.1
            if enabled { seek(min(1, max(0, fraction + step)) * 1000, 1000) }
        }
    }
}
