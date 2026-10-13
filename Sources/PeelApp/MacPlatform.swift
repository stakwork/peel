import AppKit
import Foundation
import PeelCore

// The Mac's side of `Platform`: what the model asks of AppKit, LiveKit,
// WebKit and AVKit, which it never imports itself.

extension Platform {
    static var mac: Platform {
        Platform(
            presence: MacPresence(), files: FilePanels(), pasteboard: MacPasteboard(),
            playback: MediaPlayback.shared, web: { WebPane(profile: $0) }, calls: LiveKitCalls(),
            agent: MacAgent()
        )
    }
}

/// Peel among the Mac's apps: `NSApplication` and its Dock tile.
struct MacPresence: AppPresence {
    var isFrontmost: Bool { NSApplication.shared.isActive }

    var postsNotifications: Bool { Bundle.main.bundleURL.pathExtension == "app" && !Offscreen.isOn }

    func activate() {
        NSApplication.shared.activate()
    }

    func showBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    /// Peel's page in System Settings > Notifications.
    func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension MenuPresenter: MenuHosting {
    /// The key window; with none (Peel not active, as when checked
    /// offscreen), the window the key press came to.
    var hostsKeyWindow: Bool {
        guard let window = NSApp.keyWindow ?? NSApp.currentEvent?.window else { return false }
        return window === hostWindow
    }
}

/// `Clipboard`, for the model.
struct MacPasteboard: Pasteboard {
    func copyImage(at file: URL) -> Bool { Clipboard.copyImage(at: file) }
    func clearSecret() { Clipboard.clearSecret() }
}

extension MediaPlayback: Playback {}

extension WebPane: WebPresenting {}

/// Calls over LiveKit, each a `CallSession`.
struct LiveKitCalls: CallProvider {
    func join(_ ticket: CallTicket, link: CallLink, chat: String, title: String, camera: Bool) -> any OngoingCall {
        CallSession(ticket: ticket, link: link, chat: chat, title: title, camera: camera)
    }
}

extension CallSession: OngoingCall {}

extension AppModel {
    /// The call you are on, with its media, for the call window and the
    /// sidebar's bar.
    var callSession: CallSession? { call as? CallSession }

    /// The web pane beside the chat: on the Mac, always a `WebPane`
    /// (`Platform.mac`).
    var web: WebPane { webPresenter as! WebPane }
}
