import AVKit
import SwiftUI
import PeelCore

/// The one video or recording playing, so starting another pauses it. A
/// row's player pauses when the row leaves the screen (another chat, or
/// scrolled away) unless the viewer shows it full screen. Nothing plays
/// until clicked.
@MainActor @Observable
final class MediaPlayback {
    static let shared = MediaPlayback()

    /// The attachment loaded in `player`, playing or paused.
    private(set) var current: Int64?
    private(set) var player: AVPlayer?
    private(set) var playing = false
    /// Where `current` is, in seconds.
    private(set) var time: TimeInterval = 0
    /// The video the viewer shows: it plays on while its row is off screen.
    private(set) var fullScreen: Int64?

    @ObservationIgnored private var observer: Any?

    /// The player for `id`, made (and any other stopped) when it is not the current one.
    @discardableResult
    func load(_ id: Int64, file: URL) -> AVPlayer {
        if current == id, let player { return player }
        stop()
        let player = AVPlayer(playerItem: AVPlayerItem(asset: MediaInfo.asset(file)))
        // Fires as time passes, and when playback starts, stops or jumps.
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.update(time) }
        }
        self.player = player
        current = id
        time = 0
        return player
    }

    func toggle(_ id: Int64, file: URL) {
        if current == id, playing { player?.pause() } else { play(id, file: file) }
    }

    func play(_ id: Int64, file: URL) {
        let player = load(id, file: file)
        // From the start again once it has finished.
        if let item = player.currentItem, item.duration.isNumeric, item.currentTime() >= item.duration - CMTime(value: 1, timescale: 10) {
            player.seek(to: .zero)
        }
        player.play()
    }

    func seek(_ id: Int64, file: URL, to seconds: TimeInterval) {
        let player = load(id, file: file)
        time = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Its row left the screen.
    func left(_ id: Int64) {
        guard current == id, fullScreen != id else { return }
        player?.pause()
    }

    /// The viewer shows `id` from now on, loaded where its row left it.
    func showFullScreen(_ id: Int64, file: URL) {
        fullScreen = id
        load(id, file: file)
    }

    /// The viewer closed: what it showed pauses, and its row keeps the place.
    func closeFullScreen() {
        if let fullScreen, current == fullScreen { player?.pause() }
        fullScreen = nil
    }

    /// Space in the viewer: false when it shows no video.
    func toggleFullScreen() -> Bool {
        guard let player, let fullScreen, current == fullScreen else { return false }
        if playing { player.pause() } else { player.play() }
        return true
    }

    func stop() {
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player = nil
        current = nil
        playing = false
        time = 0
    }

    private func update(_ time: CMTime) {
        if time.isNumeric { self.time = time.seconds }
        let playing = player?.timeControlStatus != .paused
        if self.playing != playing { self.playing = playing }
    }
}

extension AttachmentKind {
    /// The symbol for a video or a recording where a small mark stands for it.
    var symbol: String? {
        switch self {
        case .video: "video"
        case .audio: "waveform"
        case .image, .pdf, .text, .file: nil
        }
    }
}

/// Why a video tile or audio card cannot play; nil while it loads or plays.
private enum MediaStatus {
    case held(Int64?)
    case failed
    /// Its upload failed and this Mac no longer has the file: Retry is on the row.
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

    /// "Video · 38.3 MB", "Audio not available".
    func text(_ label: String) -> String {
        switch self {
        case .held(let size): [label, AttachmentFormat.size(size)].compactMap { $0 }.joined(separator: " · ")
        case .failed: "\(label) not available"
        case .notUploaded: "Not uploaded"
        case .unplayable: "This \(label.lowercased()) cannot be played here"
        }
    }

    /// Whether a click can still play it (by loading it).
    var canLoad: Bool {
        switch self {
        case .held, .failed: true
        case .notUploaded, .unplayable: false
        }
    }
}

/// The downloads and file reads a video tile or audio card shares: it
/// downloads as it shows (up to the limit), reads the file's info once it
/// has one, and pauses when it leaves the screen.
private struct MediaLoading: ViewModifier {
    @Environment(AppModel.self) private var model
    let message: Message
    let file: URL?
    /// The file read and what it holds (nil info: not playable).
    @Binding var read: (file: URL, info: MediaInfo?)?

    /// What was read for `file`, or is cached from an earlier row.
    static func known(_ read: (file: URL, info: MediaInfo?)?, file: URL?) -> MediaInfo?? {
        read.flatMap { $0.file == file ? .some($0.info) : nil } ?? MediaInfoCache.shared.cached(file)
    }

    func body(content: Content) -> some View {
        content
            .autoDownload(message)
            .task(id: file) {
                guard let file, let kind = message.attachmentKind else { return }
                read = (file, await MediaInfoCache.shared.info(file, kind: kind))
            }
            .onDisappear { MediaPlayback.shared.left(message.id ?? 0) }
    }
}

// MARK: - Video

/// A video in a message, sized like an image: its poster frame with a play
/// button and its length; a click plays it in place (play, pause, scrub,
/// volume), a double-click or the corner button opens it in the viewer.
/// Until the frame is ready, a plain tile; one over the download limit
/// waits for Load.
struct VideoTile: View {
    @Environment(AppModel.self) private var model
    let message: Message

    @State private var read: (file: URL, info: MediaInfo?)?
    @State private var hovering = false

    private var playback: MediaPlayback { .shared }
    private var id: Int64 { message.id ?? 0 }

    var body: some View {
        let handle = model.attachment(id)
        VStack(alignment: .leading, spacing: 4) {
            tile(handle)
            if let saved = handle.savedTo { SavedNote(file: saved) }
        }
        .modifier(MediaLoading(message: message, file: handle.file, read: $read))
    }

    private func tile(_ handle: AttachmentHandle) -> some View {
        let file = handle.file
        let known = MediaLoading.known(read, file: file)
        let info = known ?? nil
        let frame = AttachmentFormat.fitted(width: info?.size?.width ?? 0, height: info?.size?.height ?? 0, maxSide: ImageTile.maxSide)
        let inline = playback.current == id ? playback.player : nil
        return Group {
            if let inline {
                PlayerSurface(player: inline, style: .inline) { openViewer() }
            } else {
                still(handle, info: info, unplayable: known != nil && info == nil)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { if info != nil { openViewer() } }
                    .onTapGesture { if info != nil, let file { playback.play(id, file: file) } }
            }
        }
        .overlay(alignment: .topTrailing) {
            if info != nil, hovering || inline != nil {
                Button(action: openViewer) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 3)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Full screen (double-click)")
                .padding(4)
            }
        }
        .attachmentTile(fitted: frame, message: message, handle: handle)
        .onHover { hovering = $0 }
        .accessibilityLabel(message.content?.trimmed.nilIfEmpty ?? "Video")
    }

    /// The poster with play and length, or a plain tile saying where the video is.
    private func still(_ handle: AttachmentHandle, info: MediaInfo?, unplayable: Bool) -> some View {
        ZStack {
            if let poster = info?.poster {
                Image(decorative: poster, scale: 1).resizable().scaledToFill()
            } else {
                Theme.quote
            }
            if info != nil {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.45))
                    .shadow(color: .black.opacity(0.3), radius: 4)
            } else {
                waiting(handle, status: MediaStatus(message, handle, unplayable: unplayable))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let duration = info?.duration {
                Text(MediaInfo.format(duration: duration))
                    .font(Theme.font(11, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(8)
            }
        }
    }

    private func waiting(_ handle: AttachmentHandle, status: MediaStatus?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: AttachmentKind.video.symbol ?? "video")
                .font(.system(size: 22))
                .foregroundStyle(Theme.secondaryText)
            if let status {
                Text(status.text("Video"))
                    .font(Theme.font(12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
                    .help(handle.failureReason ?? "")
                if case .held = status {
                    Button("Load") { Task { await model.download(message) } }
                        .buttonStyle(GhostButtonStyle())
                }
            } else if case .downloading = handle.state, let progress = handle.progress {
                TransferBar(label: "Downloading", progress: progress).padding(.horizontal, 12)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .multilineTextAlignment(.center)
        .padding(12)
    }

    private func openViewer() {
        model.showImages([message], at: 0)
    }
}

/// AVKit's player view: play, pause, scrub and volume, with no full-screen,
/// sharing or picture-in-picture buttons of its own. A double-click calls
/// `onDoubleClick`.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    let style: AVPlayerViewControlsStyle
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = style
        view.showsFullScreenToggleButton = false
        view.showsSharingServiceButton = false
        view.allowsPictureInPicturePlayback = false
        view.videoGravity = .resizeAspect
        let doubleClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleClicked))
        doubleClick.numberOfClicksRequired = 2
        doubleClick.delaysPrimaryMouseButtonEvents = false
        view.addGestureRecognizer(doubleClick)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        context.coordinator.onDoubleClick = onDoubleClick
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        view.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator: NSObject {
        var onDoubleClick: (() -> Void)?
        @objc func doubleClicked() { onDoubleClick?() }
    }
}

// MARK: - Audio

/// A recording or audio file: play and pause, a scrubber, and the time.
/// It downloads as it shows up to the download limit; a larger one loads
/// on its first play.
struct AudioCard: View {
    @Environment(AppModel.self) private var model
    let message: Message

    @State private var read: (file: URL, info: MediaInfo?)?

    private var id: Int64 { message.id ?? 0 }

    var body: some View {
        let handle = model.attachment(id)
        let file = handle.file
        let known = MediaLoading.known(read, file: file)
        let info = known ?? nil
        let status = MediaStatus(message, handle, unplayable: known != nil && info == nil)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                // Held or failed, a click loads it (again) and plays.
                PlayButton(message: message, handle: handle, disabled: status.map { !$0.canLoad } ?? false)
                if let status {
                    Text(status.text("Audio"))
                        .font(Theme.font(12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    AudioScrubber(id: id, file: file, duration: info?.duration)
                }
            }
            AttachmentStatus(message: message, handle: handle, isRecording: true)
        }
        .attachmentCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.content?.trimmed.nilIfEmpty ?? "Audio")
        .modifier(MediaLoading(message: message, file: file, read: $read))
    }
}

/// The round play and pause button; a held recording loads, then plays.
private struct PlayButton: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let handle: AttachmentHandle
    let disabled: Bool

    var body: some View {
        let playback = MediaPlayback.shared
        let playing = playback.current == message.id && playback.playing
        let busy: Bool = if case .downloading = handle.state { true } else { false }
        Button {
            if let id = message.id, let file = handle.file {
                playback.toggle(id, file: file)
            } else {
                Task { await model.play(message) }
            }
        } label: {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.buttonText)
                .offset(x: playing ? 0 : 1)
                .buttonProgress(busy)
                .frame(width: 32, height: 32)
                .background(Theme.button, in: Circle())
                .contentShape(Circle())
                .environment(\.filledButton, true)
        }
        .buttonStyle(.plain)
        .disabled(busy || disabled || message.uploadState == .pending && handle.file == nil)
        .help(playing ? "Pause" : "Play")
    }
}

/// The scrubber and "0:12 / 1:05": the only part of a card that redraws as
/// it plays.
private struct AudioScrubber: View {
    let id: Int64
    let file: URL?
    let duration: TimeInterval?

    /// Where the scrubber is held while it is dragged.
    @State private var scrubbing: TimeInterval?

    var body: some View {
        let playback = MediaPlayback.shared
        let total = duration ?? 0
        let position = scrubbing ?? (playback.current == id ? playback.time : 0)
        VStack(alignment: .leading, spacing: 2) {
            Slider(value: Binding(get: { min(position, total) }, set: { scrubbing = $0 }), in: 0...max(total, 0.1)) { editing in
                guard !editing, let target = scrubbing, let file else { return }
                playback.seek(id, file: file, to: target)
                scrubbing = nil
            }
            .controlSize(.small)
            .disabled(file == nil || duration == nil)
            Text(duration.map { "\(MediaInfo.format(duration: position)) / \(MediaInfo.format(duration: $0))" } ?? "Audio")
                .font(Theme.font(12))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
