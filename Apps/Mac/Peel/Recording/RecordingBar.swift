import AppKit
import SwiftUI
import PeelCore
import PeelUI

/// The control bar of a screen recording, the dictation HUD's pill: before
/// it starts, Cancel and Record; while it runs, a red dot and the time
/// between Discard and Stop; in its last minute how long is left before it
/// stops itself (Account › Segments' Segment limit), and what became of a mic
/// that went quiet. Never in the recording.
struct RecordingBarView: View {
    let controller: RecordingController

    var body: some View {
        Group {
            if controller.phase == .ready { ready } else { running }
        }
        .frame(height: 28)
        .hudCapsule()
        // Room for the shadow.
        .padding(Theme.Space.sm)
        .fixedSize()
    }

    private var ready: some View {
        HStack(spacing: Theme.Space.sm) {
            HUDButton(.symbol("xmark"), label: "Cancel", filled: false, action: controller.discard)
            Text("Ready")
                .font(Theme.font(12, .semibold))
                .foregroundStyle(.white)
            Text("Up to \(controller.longest) min")
                .font(Theme.font(12, .semibold))
                .foregroundStyle(.white.opacity(0.62))
            HUDButton(.text("Record"), label: "Start recording", filled: true, action: controller.record)
        }
        .padding(.horizontal, Theme.Space.xs)
    }

    private var running: some View {
        let time = MediaInfo.format(duration: controller.elapsed)
        return HStack(spacing: Theme.Space.sm) {
            HUDButton(.symbol("xmark"), label: "Discard the recording", filled: false, action: controller.discard)
            Circle()
                .fill(Theme.destructive)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(time)
                .font(Theme.font(12, .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                // Room for "10:00", so the bar keeps its size.
                .frame(minWidth: 36, alignment: .leading)
                .accessibilityLabel("Recording, \(time)")
            if let left = controller.timeLeft {
                let shown = MediaInfo.format(duration: left.rounded(.up))
                Text("\(shown) left")
                    .font(Theme.font(12, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.hudWarning)
                    .frame(minWidth: 52, alignment: .leading)
                    .accessibilityLabel("\(shown) left before the recording stops")
            }
            if let mic = controller.micNote {
                Text(mic)
                    .font(Theme.font(12, .semibold))
                    .foregroundStyle(Theme.hudWarning)
            }
            HUDButton(.symbol("checkmark"), label: "Stop and keep the recording", filled: true, action: controller.stop)
        }
        .padding(.horizontal, Theme.Space.xs)
    }
}

/// The bar's window: a panel that never takes the keyboard from the app
/// being recorded, at the bottom centre of the recorded display.
@MainActor
final class RecordingBarPanel: HUDPanel {
    private let host: NSHostingView<RecordingBarView>

    init(controller: RecordingController) {
        host = NSHostingView(rootView: RecordingBarView(controller: controller))
        super.init()
        contentView = host
        isMovableByWindowBackground = true
        // Never in the recording, from its first frame: the cloak only
        // reaches it after an event in Peel.
        sharingType = .none
        setContentSize(host.fittingSize)
    }

    /// Sized to what it shows now (Ready, or the time), bottom centre of `screen`.
    func show(on screen: NSScreen?) {
        host.layoutSubtreeIfNeeded()
        setContentSize(host.fittingSize)
        if let area = (screen ?? NSScreen.main)?.visibleFrame {
            setFrameOrigin(NSPoint(x: area.midX - frame.width / 2, y: area.minY + DictationDefaults.hudBottomInset))
        }
        orderFrontRegardless()
    }

    /// Sized again to what it shows, where it was put or dragged: the same
    /// centre and bottom.
    func refit() {
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY, width: size.width, height: size.height), display: true)
    }
}
