import PeelCore
import PeelUI
import SwiftUI

/// A voice message's controls: play or pause (a spinner while it uploads,
/// downloads or its length is read), a bar to drag or tap to seek, and
/// "current / total". The phone's `VoiceBubble` and the Mac's audio card
/// put it in their own chrome. `autoDownload` is false where the host
/// already downloads (the Mac's `MediaLoading`).
struct VoiceControls: View {
    @Environment(AppModel.self) private var model
    let message: Message
    var autoDownload = true

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
                .frame(width: max(36, VoiceStyle.target), height: max(36, VoiceStyle.target))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!ready)
            .accessibilityLabel(label(state))
            VStack(alignment: .leading, spacing: 4) {
                SeekBar(fraction: fraction, enabled: ready && (player.duration ?? 0) > 0) { x, width in
                    player.seek(to: VoiceMessage.seekTime(x: x, width: width, total: player.duration ?? 0))
                }
                Text(caption(state))
                    .voiceCaption()
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .task(id: file) {
            if let file {
                await player.load(file)
            } else if autoDownload, handle?.failureReason == nil {
                await model.autoDownload(message)
            }
        }
        .onDisappear { player.stop() }
    }

    private func label(_ state: VoiceMessage.RowState) -> String {
        switch state {
        case .ready: player.isPlaying ? "Pause" : "Play"
        case .failed: "Can't play"
        case .uploading, .loading: "Loading"
        }
    }

    private func caption(_ state: VoiceMessage.RowState) -> String {
        switch state {
        case .ready: VoiceMessage.timeLabel(current: player.time, total: player.duration)
        case .uploading: "Uploading…"
        case .loading: "Loading…"
        case .failed: "Can't play this audio"
        }
    }
}

/// A thin bar that fills with `fraction`; a tap or drag on it seeks.
struct SeekBar: View {
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
