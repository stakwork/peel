import SwiftUI
import PeelCore

/// One sender's images at full size over the window: who sent them and
/// when, Reply, Copy and Save as…, arrows (or the arrow keys) between them,
/// the caption, and a strip of the run. Escape or a click outside closes.
struct ImageViewer: View {
    @Environment(AppModel.self) private var model
    let state: ImageViewerState

    @State private var image: CGImage?
    @State private var keys = KeyMonitor()

    private var current: Message { state.current }

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
                        if let image {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else if case .failed(let reason) = handle.state {
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
            await model.download(current)
            if let file = model.attachment(current.id ?? 0).file {
                image = await ImageCache.shared.image(file, maxPixels: 4096)
            }
        }
        .onAppear {
            let model = model
            keys.start { event in
                switch event.keyCode {
                case 53: model.viewer = nil
                case 123: model.stepViewer(-1)
                case 124: model.stepViewer(1)
                default: return false
                }
                return true
            }
        }
        .onDisappear { keys.stop() }
        .accessibilityAddTraits(.isModal)
    }

    private var header: some View {
        let conversation = model.conversations.first { $0.chat == current.chat }
        let isTribe = conversation?.isTribe ?? false
        let sender = model.sender(of: current)
        return HStack(spacing: 10) {
            Avatar(name: sender.avatarName, url: sender.photoURL, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(sender.name).font(Theme.font(14, .bold))
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
            CopyButton("Copy") { model.copyImage(current) }
                // A fresh button per image, so one copied does not mark the next.
                .id(current.id)
                .buttonStyle(GhostButtonStyle())
                .disabled(image == nil)
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
