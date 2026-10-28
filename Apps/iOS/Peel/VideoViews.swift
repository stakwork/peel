import AVKit
import PeelCore
import PeelUI
import SwiftUI

// Received video on the phone, as the Mac's `VideoTile`: a poster with a
// play button and its length, downloaded as it shows up to
// `Engine.autoDownloadLimit`, a larger one waiting for a tap; a tap plays
// it in place with the system's controls.

/// The one video playing, so starting another stops it. A row's video
/// pauses when the row leaves the screen.
@MainActor @Observable
final class VideoPlayback {
    static let shared = VideoPlayback()

    /// The attachment loaded in `player`, playing or paused.
    private(set) var current: Int64?
    private(set) var player: AVPlayer?

    func play(_ id: Int64, file: URL) {
        let player: AVPlayer
        if current == id, let loaded = self.player {
            player = loaded
        } else {
            self.player?.pause()
            player = AVPlayer(playerItem: AVPlayerItem(asset: MediaInfo.asset(file)))
            self.player = player
            current = id
        }
        // Sound with the silent switch on, as for a voice message.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        // From the start again once it has finished.
        if let item = player.currentItem, item.duration.isNumeric, item.currentTime() >= item.duration - CMTime(value: 1, timescale: 10) {
            player.seek(to: .zero)
        }
        player.play()
    }

    /// Its row left the screen.
    func left(_ id: Int64) {
        if current == id { player?.pause() }
    }

    func stop() {
        player?.pause()
        player = nil
        current = nil
    }
}

/// A video in a message, as wide as an image tile.
struct VideoTile: View {
    @Environment(AppModel.self) private var model
    let message: Message

    @State private var read: (file: URL, info: MediaInfo?)?
    @State private var sharing: SharedFileItem?

    /// What was read for `file`, or is cached from an earlier row: nil when
    /// not read yet, nil inside when AVFoundation cannot play it.
    private static func known(_ read: (file: URL, info: MediaInfo?)?, file: URL?) -> MediaInfo?? {
        read.flatMap { $0.file == file ? .some($0.info) : nil } ?? MediaInfoCache.shared.cached(file)
    }

    private var playback: VideoPlayback { .shared }
    private var id: Int64 { message.id ?? 0 }

    var body: some View {
        let handle = model.attachment(id)
        let file = handle.file
        let known = Self.known(read, file: file)
        let info: MediaInfo? = known.flatMap { $0 }
        let aspect = info?.size.map { $0.height > 0 ? min(max($0.width / $0.height, 0.5), 2) : 16 / 9 } ?? 16 / 9
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        let status = Status(message, handle, unplayable: known != nil && info == nil)
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: ImageTile.side)
            .overlay {
                if playback.current == id, let player = playback.player, file != nil {
                    VideoPlayer(player: player)
                } else {
                    poster(info?.poster, duration: info?.duration, handle: handle, status: status)
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.divider))
            .overlay(alignment: .topTrailing) {
                if file != nil, message.uploadState != .pending, status == nil {
                    Button(action: share) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(.black.opacity(0.5), in: Circle())
                            .frame(width: Theme.touchTarget, height: Theme.touchTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Share video")
                }
            }
            .overlay(alignment: .bottom) {
                if message.fromMe, message.uploadState == .pending {
                    TransferLine(label: "Uploading", progress: handle.progress)
                        .padding(Theme.Space.sm)
                        .background(Theme.input.opacity(0.92), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                        .padding(Theme.Space.sm)
                }
            }
            .sheet(item: $sharing) { shared in
                FileShareSheet(url: shared.url).presentationDetents([.medium, .large])
            }
            // Again once an upload of ours is done (the Mac's `AutoDownload`).
            .task(id: "\(id)/\(message.upload ?? "")") { await model.autoDownload(message) }
            .task(id: file) {
                guard let file else { return }
                read = (file, await MediaInfoCache.shared.info(file, kind: .video))
            }
            .onDisappear { playback.left(id) }
    }

    /// Why it cannot play, nil while it loads or plays.
    private enum Status: Equatable {
        case held(Int64?)
        case failed
        /// Its upload failed and the file is gone: Retry is in the row's menu.
        case notUploaded
        case unplayable

        @MainActor init?(_ message: Message, _ handle: AttachmentHandle, unplayable: Bool) {
            if unplayable { self = .unplayable; return }
            switch handle.state {
            case .held(let size): self = .held(size)
            case .failed: self = .failed
            case .idle where handle.file == nil && message.fromMe && message.uploadState == .failed: self = .notUploaded
            case .idle, .downloading, .ready: return nil
            }
        }

        /// "Video · 38.3 MB", "Video not available".
        var text: String {
            switch self {
            case .held(let size): ["Video", AttachmentFormat.size(size)].compactMap { $0 }.joined(separator: " · ")
            case .failed: "Video not available"
            case .notUploaded: "Not uploaded"
            case .unplayable: "Can't play this video"
            }
        }

        /// Whether a tap can still play it (by loading it).
        var canLoad: Bool {
            switch self {
            case .held, .failed: true
            case .notUploaded, .unplayable: false
            }
        }
    }

    private func poster(_ image: CGImage?, duration: TimeInterval?, handle: AttachmentHandle, status: Status?) -> some View {
        Button(action: tap) {
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    Theme.quote
                }
                content(handle: handle, status: status, duration: duration)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(status.map { !$0.canLoad } ?? false)
        .accessibilityLabel(label(status: status, duration: duration))
        .accessibilityHint(status == nil || status?.canLoad == true ? "Plays the video" : "")
    }

    @ViewBuilder
    private func content(handle: AttachmentHandle, status: Status?, duration: TimeInterval?) -> some View {
        if case .downloading = handle.state {
            VStack(spacing: Theme.Space.sm) {
                if let progress = handle.progress, progress.total > 0 {
                    ProgressView(value: Double(progress.bytes), total: Double(progress.total)).tint(Theme.accent)
                    Text(AttachmentFormat.progress(progress.bytes, of: progress.total))
                        .phoneFont(.time).monospacedDigit().foregroundStyle(Theme.secondaryText)
                } else {
                    ProgressView()
                }
            }
            .padding(Theme.Space.lg)
        } else if let status {
            VStack(spacing: Theme.Space.xs) {
                Image(systemName: status.canLoad ? "arrow.down.circle" : "video.slash")
                    .font(.system(size: 28))
                Text(status.text).phoneFont(.secondary)
                if case .failed = status, let reason = handle.failureReason {
                    Text(reason).phoneFont(.time).lineLimit(2).multilineTextAlignment(.center)
                }
            }
            .foregroundStyle(Theme.secondaryText)
            .padding(Theme.Space.md)
        } else if handle.file != nil {
            Image(systemName: "play.fill")
                .font(.system(size: 20))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(.black.opacity(0.5), in: Circle())
                .accessibilityHidden(true)
            if let duration {
                Text(MediaInfo.format(duration: duration))
                    .phoneFont(.badge).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.5), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(Theme.Space.sm)
                    .accessibilityHidden(true)
            }
        } else {
            ProgressView()
        }
    }

    private func label(status: Status?, duration: TimeInterval?) -> String {
        if let status { return status.text }
        return ["Video", duration.map(MediaInfo.format(duration:))].compactMap { $0 }.joined(separator: ", ")
    }

    /// Plays it, downloading first when it was held or failed (the tap
    /// asks for it, past the auto-download limit).
    private func tap() {
        if let file = model.attachment(id).file {
            playback.play(id, file: file)
        } else {
            Task { await model.play(message) }
        }
    }

    private func share() {
        guard let file = model.attachment(id).file else { return }
        let name = model.attachment(id).downloaded?.fileName ?? message.fileName
        Task {
            if let url = try? await FileCopy.named(file, name: name, mediaType: message.mediaType) {
                sharing = SharedFileItem(url: url)
            }
        }
    }
}
