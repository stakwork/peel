import AVKit
import PeelCore
import PeelUI
import SwiftUI

// Received video on the phone, as the Mac's `VideoTile`: a poster with a
// play button and its length, downloaded as it shows up to
// `Engine.autoDownloadLimit`, a larger one waiting for a tap; a tap plays
// it full screen (`VideoViewer`) with the system's controls; the tile is
// only the poster.

/// The one video open full screen (`VideoViewer`), set by a tap on its
/// tile or by the model once a held video has downloaded.
@MainActor @Observable
final class VideoPlayback {
    static let shared = VideoPlayback()

    /// A video to show full screen: the attachment and its local file.
    struct Request: Identifiable, Equatable {
        let id: Int64
        let file: URL
    }

    private(set) var request: Request?

    func play(_ id: Int64, file: URL) { request = Request(id: id, file: file) }

    func stop() { request = nil }
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

    private static let defaultAspect: CGFloat = CGFloat(16) / CGFloat(9)

    /// Width over height of the video, clamped; 16:9 until known.
    private func aspect(of info: MediaInfo?) -> CGFloat {
        guard let size = info?.size else { return Self.defaultAspect }
        let height: CGFloat = CGFloat(size.height)
        let width: CGFloat = CGFloat(size.width)
        if height > 0 {
            let ratio: CGFloat = width / height
            return min(max(ratio, CGFloat(0.5)), CGFloat(2))
        }
        return Self.defaultAspect
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
    }

    var body: some View {
        let handle: AttachmentHandle = model.attachment(id)
        let file: URL? = handle.file
        let known: MediaInfo?? = Self.known(read, file: file)
        let info: MediaInfo? = known.flatMap { $0 }
        let status: Status? = Status(message, handle, unplayable: known != nil && info == nil)
        let base = tile(info: info, file: file, handle: handle, status: status)
        base
            .sheet(item: $sharing) { shared in
                FileShareSheet(url: shared.url).presentationDetents([.medium, .large])
            }
            // Again once an upload of ours is done (the Mac's `AutoDownload`).
            .task(id: "\(id)/\(message.upload ?? "")") { await model.autoDownload(message) }
            .task(id: file) {
                guard let file else { return }
                read = (file, await MediaInfoCache.shared.info(file, kind: .video))
            }
            .fullScreenCover(item: Binding(
                get: { playback.request.flatMap { $0.id == id ? $0 : nil } },
                set: { if $0 == nil { playback.stop() } }
            )) { VideoViewer(file: $0.file) }
    }

    private func tile(info: MediaInfo?, file: URL?, handle: AttachmentHandle, status: Status?) -> some View {
        let clipped = Color.clear
            .aspectRatio(aspect(of: info), contentMode: .fit)
            .frame(maxWidth: ImageTile.side)
            .overlay { media(info: info, file: file, handle: handle, status: status) }
            .clipShape(shape)
        return clipped
            .overlay(shape.strokeBorder(Theme.divider))
            .overlay(alignment: .topTrailing) { shareButton(file: file, status: status) }
            .overlay(alignment: .bottom) { uploadLine(handle: handle) }
    }

    @ViewBuilder
    private func media(info: MediaInfo?, file: URL?, handle: AttachmentHandle, status: Status?) -> some View {
        poster(info?.poster, duration: info?.duration, handle: handle, status: status)
    }

    @ViewBuilder
    private func shareButton(file: URL?, status: Status?) -> some View {
        if file != nil, message.uploadState != .pending, status == nil {
            Button(action: share) {
                shareIcon
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share video")
        }
    }

    private var shareIcon: some View {
        Image(systemName: "square.and.arrow.up")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(.black.opacity(0.5), in: Circle())
            .frame(width: Theme.touchTarget, height: Theme.touchTarget)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func uploadLine(handle: AttachmentHandle) -> some View {
        if message.fromMe, message.uploadState == .pending {
            let backdrop = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            TransferLine(label: "Uploading", progress: handle.progress)
                .padding(Theme.Space.sm)
                .background(Theme.input.opacity(0.92), in: backdrop)
                .padding(Theme.Space.sm)
        }
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
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(status == nil ? "Opens the video full screen" : status?.canLoad == true ? "Loads the video" : "")
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

    /// Opens it full screen, downloading first when it was held or failed (the tap
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
