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
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
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
