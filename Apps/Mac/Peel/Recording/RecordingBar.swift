import AppKit
import SwiftUI
import PeelCore
import PeelUI

/// The control bar of a screen recording, the dictation HUD's pill: before
/// it starts, Cancel and Record; while it runs, a red dot and the time
/// between ✕ (a menu: Start over or Discard) and Pause and Stop; paused, the time held and dimmed, a
/// ring for the dot and Play where Pause was; in its last minute how long is
/// left before it stops itself (Account › Segments' Segment limit), and what
/// became of a mic that went quiet. Never in the recording.
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
            HUDButton(.text(String(localized: "Record")), label: String(localized: "Start recording"), filled: true, action: controller.record)
        }
        .padding(.horizontal, Theme.Space.xs)
    }

    private var running: some View {
        let time = MediaInfo.format(duration: controller.elapsed)
        let paused = controller.phase == .paused
        return HStack(spacing: Theme.Space.sm) {
            // Never thrown away in one click (Tom, 2026-11-27): a menu above
            // the bar, Start over for another take or Discard to end it.
            HUDButton(.symbol("xmark"), label: String(localized: "Start over or discard the recording"), filled: false) {
                controller.endMenuOpen.toggle()
            }
            Group {
                if paused {
                    Circle().strokeBorder(.white.opacity(0.62), lineWidth: 1.5)
                } else {
                    Circle().fill(Theme.destructive)
                }
            }
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
            Text(time)
                .font(Theme.font(12, .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(paused ? 0.62 : 1))
                // Room for "10:00", so the bar keeps its size.
                .frame(minWidth: 36, alignment: .leading)
                .accessibilityLabel(paused ? String(localized: "Paused, \(time)") : String(localized: "Recording, \(time)"))
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
            if paused {
                HUDButton(.symbol("record.circle.fill"), label: "Resume recording", filled: false, action: controller.resume)
            } else {
                HUDButton(.symbol("pause.fill"), label: "Pause the recording", filled: false, action: controller.pause)
            }
            HUDButton(.symbol("checkmark"), label: "Stop and keep the recording", filled: true, action: controller.stop)
        }
        .padding(.horizontal, Theme.Space.xs)
    }
}

/// What ✕ opens while recording, just above the bar (Tom, 2026-11-27):
/// Start over for another take, or Discard to end it, in the bar's own dark
/// look rather than the system menu's.
struct RecordingEndMenu: View {
    let controller: RecordingController

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            EndMenuItem(title: String(localized: "Start over"), systemImage: "arrow.counterclockwise",
                        tint: .white, action: controller.startOver)
            EndMenuItem(title: String(localized: "Discard recording"), systemImage: "xmark",
                        tint: Theme.destructive, action: controller.discard)
        }
        .padding(5)
        .frame(width: 190)
        .hudBox(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        // Room for the shadow, as the bar has.
        .padding(Theme.Space.sm)
        .fixedSize()
    }
}

/// One of the menu's two choices: lit in the accent under the pointer.
private struct EndMenuItem: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14)
                Text(title).font(Theme.font(13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? Color.white : tint)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(hovering ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The bar's window: a panel that never takes the keyboard from the app
/// being recorded, at the bottom centre of the recorded display.
@MainActor
final class RecordingBarPanel: HUDPanel {
    private let host: NSHostingView<RecordingBarView>
    private let controller: RecordingController
    /// ✕'s menu, a window of its own above the bar that moves with it.
    private lazy var endMenu: HUDPanel = {
        let panel = HUDPanel()
        let host = NSHostingView(rootView: RecordingEndMenu(controller: controller))
        panel.contentView = host
        panel.sharingType = .none
        panel.setContentSize(host.fittingSize)
        return panel
    }()
    /// A click anywhere but the bar and its menu closes the menu.
    private var clickWatchers: [Any] = []

    init(controller: RecordingController) {
        self.controller = controller
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

    /// Opens ✕'s menu above the bar, its left edge over ✕'s, or closes it.
    func showEndMenu(_ open: Bool) {
        if open {
            // Both windows keep `Space.sm` round them for the shadow: a 6 pt gap between what shows.
            endMenu.setFrameOrigin(NSPoint(x: frame.minX, y: frame.maxY - 2 * Theme.Space.sm + 6))
            addChildWindow(endMenu, ordered: .above)
            endMenu.orderFrontRegardless()
            let close: @MainActor () -> Void = { [weak self] in self?.controller.endMenuOpen = false }
            clickWatchers = [
                NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
                    MainActor.assumeIsolated { close() }
                },
                NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                    MainActor.assumeIsolated {
                        if let self, event.window !== self, event.window !== self.endMenu { close() }
                    }
                    return event
                },
            ].compactMap { $0 }
        } else {
            clickWatchers.forEach(NSEvent.removeMonitor)
            clickWatchers = []
            removeChildWindow(endMenu)
            endMenu.orderOut(nil)
        }
    }
}
