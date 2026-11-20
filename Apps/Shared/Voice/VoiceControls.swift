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
        // Not here and not coming by itself (Auto download media is off, held by its size, or a
        // download that failed in a way that may pass): a tap fetches it.
        let needsTap = file == nil && state == .loading
            && (model.awaitsManualDownload(message) || handle?.isHeld == true || handle?.isRetrying == true)
        let waiting = file == nil && state == .loading && !needsTap && handle?.isIdle == true
        let fraction = VoiceMessage.fraction(current: player.time, total: player.duration)
        HStack(spacing: Theme.Space.md) {
            Button {
                if needsTap { Task { await model.download(message) } } else { player.toggle() }
            } label: {
                Group {
                    if needsTap {
                        Image(systemName: "arrow.down.circle").font(.system(size: 16))
                    } else if state == .loading || state == .uploading {
                        ProgressView().controlSize(.small).tint(Theme.buttonText)
                    } else {
                        Image(systemName: state == .failed ? "exclamationmark.triangle" : player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16))
                    }
                }
                .foregroundStyle(Theme.buttonText)
                .frame(width: 36, height: 36)
                .background(Theme.button.opacity(ready || needsTap ? 1 : 0.4), in: Circle())
                .frame(width: max(36, VoiceStyle.target), height: max(36, VoiceStyle.target))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!ready && !needsTap)
            .accessibilityLabel(needsTap ? String(localized: "Download", table: "Shared") : label(state))
            VStack(alignment: .leading, spacing: 4) {
                SeekBar(fraction: fraction, enabled: ready && (player.duration ?? 0) > 0) { x, width in
                    player.seek(to: VoiceMessage.seekTime(x: x, width: width, total: player.duration ?? 0))
                }
                Text(needsTap ? tapCaption(handle) : waiting ? String(localized: "Waiting to download", table: "Shared") : caption(state))
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

    private func tapCaption(_ handle: AttachmentHandle?) -> String {
        if handle?.isRetrying == true { return String(localized: "Couldn't download yet - tap to retry", table: "Shared") }
        if case .held(let size)? = handle?.state {
            return [String(localized: "Tap to download", table: "Shared"), AttachmentFormat.size(size)].compactMap { $0 }.joined(separator: " · ")
        }
        return String(localized: "Tap to download", table: "Shared")
    }

    private func label(_ state: VoiceMessage.RowState) -> String {
        switch state {
        case .ready: player.isPlaying ? String(localized: "Pause", table: "Shared") : String(localized: "Play", table: "Shared")
        case .failed: String(localized: "Can't play", table: "Shared")
        case .uploading, .loading: String(localized: "Loading", table: "Shared")
        }
    }

    private func caption(_ state: VoiceMessage.RowState) -> String {
        switch state {
        case .ready: VoiceMessage.timeLabel(current: player.time, total: player.duration)
        case .uploading: String(localized: "Uploading…", table: "Shared")
        case .loading: String(localized: "Loading…", table: "Shared")
        case .failed: String(localized: "Can't play this audio", table: "Shared")
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
        .accessibilityLabel(Text("Position", tableName: "Shared"))
        .accessibilityValue(String(localized: "\(Int(fraction * 100)) percent", table: "Shared"))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.1 : -0.1
            if enabled { seek(min(1, max(0, fraction + step)) * 1000, 1000) }
        }
    }
}
