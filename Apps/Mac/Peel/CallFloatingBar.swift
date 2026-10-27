import AppKit
import SwiftUI
import PeelUI

/// The call's controls in a small pill that floats above other windows
/// while the call window is not the key window, so you can mute, share or
/// leave from another window or while sharing your screen. Hidden when the
/// call window is key again, closes, or the call ends.
///
/// Owned by the call window's view (`attach` on appear, `detach` on
/// disappear). The panel never takes the keyboard or activates Peel, so
/// clicking it leaves the call window as it was. It is out of every screen
/// capture (`sharingType = .none`; share filters come from the system
/// picker, so there is none to exclude it from).
@MainActor
final class CallFloatingBar {
    /// The bar shows while the call window is not key, during a call that
    /// is up (connected, or reconnecting).
    static func shouldShow(windowIsKey: Bool, state: CallSession.State, callPresent: Bool) -> Bool {
        guard callPresent, !windowIsKey else { return false }
        return state == .connected || state == .reconnecting
    }

    /// Where it was last dragged to, kept between shows and calls.
    private static var remembered: NSPoint?
    /// Distance from the bottom of the screen's visible area.
    private static let bottomInset: CGFloat = 15

    private var panel: CallBarPanel?
    private weak var window: NSWindow?
    private var call: CallSession?
    private var leave: () -> Void = {}
    private var watches: [any NSObjectProtocol] = []
    private var moveWatch: (any NSObjectProtocol)?

    isolated deinit {
        watches.forEach(NotificationCenter.default.removeObserver)
        if let moveWatch { NotificationCenter.default.removeObserver(moveWatch) }
        panel?.close()
    }

    /// Follows `window`, the call window, for `call`. `leave` is the in-call
    /// Leave's own action.
    func attach(window: NSWindow, call: CallSession, leave: @escaping () -> Void) {
        detach()
        self.window = window
        self.call = call
        self.leave = leave
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
        ]
        watches = names.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                // The next key window is set only after the notification.
                MainActor.assumeIsolated { self?.update() }
            }
        }
        watches.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.detach() }
        })
        update()
    }

    /// Stops following and closes the panel.
    func detach() {
        watches.forEach(NotificationCenter.default.removeObserver)
        watches = []
        window = nil
        call = nil
        hide()
    }

    /// Shows or hides it for the call window's and the call's state now.
    func update() {
        guard let window, let call else { return hide() }
        // A menu or panel opened from the call window is not "away".
        let key = window.isKeyWindow || (NSApp.keyWindow.map { window.childWindows?.contains($0) == true } ?? false)
        if Self.shouldShow(windowIsKey: key, state: call.state, callPresent: true) { show(call) } else { hide() }
    }

    private func show(_ call: CallSession) {
        guard let window else { return }
        let panel = self.panel ?? makePanel()
        if !panel.isVisible {
            let bar = CallFloatingBarView(call: call, returnToCall: { [weak window] in
                guard let window else { return }
                NSApplication.shared.activate()
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            }, leave: leave)
            let host = NSHostingView(rootView: bar)
            panel.contentView = host
            panel.setFrame(NSRect(origin: origin(for: host.fittingSize), size: host.fittingSize), display: true)
        }
        panel.orderFrontRegardless()
    }

    private func hide() {
        guard let panel else { return }
        panel.orderOut(nil)
        // Nothing keeps drawing, or ticking, while it is hidden.
        panel.contentView = nil
    }

    private func makePanel() -> CallBarPanel {
        let panel = CallBarPanel()
        self.panel = panel
        moveWatch = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak panel] _ in
            MainActor.assumeIsolated { if let panel, panel.isVisible { Self.remembered = panel.frame.origin } }
        }
        return panel
    }

    /// Where it was dragged to if that is still on a screen, else bottom
    /// centre of the main screen.
    private func origin(for size: CGSize) -> NSPoint {
        if let remembered = Self.remembered,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(NSRect(origin: remembered, size: size)) }) {
            return remembered
        }
        let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        return NSPoint(x: area.midX - size.width / 2, y: area.minY + Self.bottomInset)
    }
}

/// Borderless, non-activating and never key, on every Space and over
/// full-screen apps; dragged by its background.
@MainActor
private final class CallBarPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        // Never in a share or a screenshot.
        sharingType = .none
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A compact dark pill with the in-call actions, the same ones as the
/// call window's control bar.
private struct CallFloatingBarView: View {
    let call: CallSession
    let returnToCall: () -> Void
    let leave: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            IconButton(help: call.micOn ? "Mute" : "Unmute", variant: .outline, action: call.toggleMicrophone) {
                Image(systemName: call.micOn ? "mic" : "mic.slash")
                    .foregroundStyle(call.micOn ? Theme.text : Theme.secondaryText)
            }
            .disabled(call.micAccess == .refused)
            IconButton(help: call.cameraOn ? "Turn camera off" : "Turn camera on", variant: .outline, action: call.toggleCamera) {
                Image(systemName: call.cameraOn ? "video" : "video.slash")
                    .foregroundStyle(call.cameraOn ? Theme.text : Theme.secondaryText)
            }
            .disabled(call.cameraAccess == .refused)
            share
            IconButton("arrow.up.forward.square", help: "Return to call", variant: .outline, action: returnToCall)
            Button(action: leave) {
                HStack(spacing: 6) {
                    Image(systemName: "phone.down.fill").font(.system(size: 12))
                    Text("Leave").font(Theme.font(12, .bold))
                }
                .foregroundStyle(Theme.buttonText)
                .padding(.horizontal, Theme.Space.md)
                .frame(height: IconButton<Image>.Size.md.side)
                .background(Theme.destructive, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Leave the call")
            .accessibilityLabel("Leave the call")
        }
        .padding(.vertical, Theme.Space.md)
        .padding(.horizontal, Theme.Space.lg)
        .background(Theme.callBackground, in: Capsule())
        .overlay { Capsule().strokeBorder(Theme.callDivider, lineWidth: 1) }
        .fixedSize()
    }

    /// Share the entire screen, or stop sharing.
    @ViewBuilder private var share: some View {
        if call.sharing != nil {
            IconButton("rectangle.inset.filled.and.person.filled", help: "Stop sharing", variant: .outline, lit: true) {
                call.stopScreenShare()
            }
        } else {
            IconButton("rectangle.inset.filled.and.person.filled", help: "Share your entire screen", variant: .outline) {
                call.startScreenShare(.display)
            }
            .disabled(call.state != .connected)
        }
    }
}
