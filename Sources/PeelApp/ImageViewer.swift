import SwiftUI
import PeelCore

/// One sender's images at full size over the window: who sent them and
/// when, Reply, Copy and Save as…, arrows (or the arrow keys) between them,
/// the caption, and a strip of the run. A video plays here with AVKit's
/// controls (Space plays and pauses), carrying on from its row, with
/// Download and Save as…. Escape or a click outside closes.
struct ImageViewer: View {
    @Environment(AppModel.self) private var model
    let state: ImageViewerState

    @State private var image: CGImage?
    @State private var keys = KeyMonitor()
    /// The main window's presenter, whose window alone gives the viewer its keys.
    @Environment(\.menuPresenter) private var presenter

    private var current: Message { state.current }
    private var isVideo: Bool { current.attachmentKind == .video }
    private var playback: MediaPlayback { .shared }

    var body: some View {
        let handle = model.attachment(current.id ?? 0)
        ZStack {
            Color.black.opacity(0.86)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
            VStack(spacing: 14) {
                header
                HStack(spacing: 18) {
                    arrow("chevron.left", help: "Previous (Left arrow)", enabled: state.index > 0) { model.stepViewer(-1) }
                    Group {
                        if isVideo, playback.current == current.id, let player = playback.player {
                            PlayerSurface(player: player, style: .floating)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else if let image {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else if let reason = handle.failureReason {
                            Text(reason)
                                .font(Theme.font(13))
                                .foregroundStyle(Theme.secondaryText)
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    arrow("chevron.right", help: "Next (Right arrow)", enabled: state.index < state.messages.count - 1) {
                        model.stepViewer(1)
                    }
                }
                if let caption = current.content?.trimmed.nilIfEmpty {
                    Text(caption)
                        .font(Theme.font(14))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                if state.messages.count > 1 {
                    HStack(spacing: 8) {
                        ForEach(Array(state.messages.enumerated()), id: \.element.id) { index, message in
                            Button {
                                model.viewer?.index = index
                            } label: {
                                AttachmentMark(message: message, size: 44)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .strokeBorder(index == state.index ? Theme.accent : .clear, lineWidth: 2)
                                    )
                                    .opacity(index == state.index ? 1 : 0.6)
                            }
                            .buttonStyle(.plain)
                        }
                        Text("\(state.index + 1) of \(state.messages.count)")
                            .font(Theme.font(12))
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.leading, 6)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
        .foregroundStyle(.white)
        .task(id: current.id) {
            image = nil
            // A video stepped away from pauses, as closing the viewer does.
            playback.closeFullScreen()
            let message = current
            await model.download(message)
            let handle = model.attachment(message.id ?? 0)
            guard let file = handle.file else { return }
            if message.attachmentKind == .video {
                // The row's player, where it was; nothing starts by itself.
                // Not if the viewer closed or moved on while it downloaded.
                guard !Task.isCancelled, model.attachmentKind(of: message) == .video, let id = message.id else { return }
                playback.showFullScreen(id, file: file)
            } else {
                let decoded = await ImageCache.shared.image(file, maxPixels: 4096)
                // A slow decode that lands after a step belongs to the image left.
                guard !Task.isCancelled else { return }
                image = decoded
            }
        }
        .onAppear {
            let model = model, presenter = presenter
            keys.start { event in
                // Escape and the arrows in the call window are not the viewer's.
                guard let window = presenter?.hostWindow, event.window === window else { return false }
                switch event.keyCode {
                case 53: model.viewer = nil
                case 123: model.stepViewer(-1)
                case 124: model.stepViewer(1)
                case 49:
                    // Space: play or pause the video shown.
                    return MediaPlayback.shared.toggleFullScreen()
                default: return false
                }
                return true
            }
        }
        .onDisappear {
            keys.stop()
            playback.closeFullScreen()
        }
        .accessibilityAddTraits(.isModal)
    }

    private var header: some View {
        let conversation = model.conversations.first { $0.chat == current.chat }
        let isTribe = conversation?.isTribe ?? false
        let sender = model.sender(of: current)
        return HStack(spacing: 10) {
            Avatar(name: sender.avatarName, url: sender.photoURL, size: 32, hue: sender.hue)
            VStack(alignment: .leading, spacing: 1) {
                Text(sender.name).font(Theme.font(14, .bold)).foregroundStyle(sender.hue.name)
                Text("\(isTribe ? "#" : "")\(conversation?.name ?? "") · \(Formatting.dayHeading(current.date)) \(current.date.formatted(.dateTime.hour().minute()))")
                    .font(Theme.font(12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if current.isLinkable(inTribe: isTribe) {
                Button {
                    let message = current
                    close()
                    model.startReply(to: message, from: model.composer(for: message))
                } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                    .buttonStyle(GhostButtonStyle())
            }
            if isVideo {
                let handle = model.attachment(current.id ?? 0)
                if let saved = handle.savedTo {
                    Button { model.showInFinder(saved) } label: { Label("Show in Finder", systemImage: "folder") }
                        .buttonStyle(GhostButtonStyle())
                        .help("Saved to Downloads as \(saved.lastPathComponent)")
                } else {
                    let message = current
                    Button { Task { await model.saveToDownloads(message) } } label: {
                        Label("Download", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(GhostButtonStyle())
                    .help("Save to Downloads")
                }
            } else {
                CopyButton("Copy") { model.copyImage(current) }
                    // A fresh button per image, so one copied does not mark the next.
                    .id(current.id)
                    .buttonStyle(GhostButtonStyle())
                    .disabled(image == nil)
            }
            Button { Task { await model.save(current) } } label: { Label("Save as…", systemImage: "square.and.arrow.down") }
                .buttonStyle(GhostButtonStyle())
            HoverIconButton(systemImage: "xmark", help: "Close (Escape)", action: close)
        }
    }

    private func arrow(_ systemImage: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Theme.menu, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0)
        .disabled(!enabled)
        .help(help)
    }

    private func close() {
        model.viewer = nil
    }
}
