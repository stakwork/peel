import AppKit
import Foundation
import PeelCore
import PeelUI

// The Mac's side of `Platform`: what the model asks of AppKit, LiveKit,
// WebKit and AVKit, which it never imports itself.

extension Platform {
    /// A new set each call: the app makes its one model with it.
    static func mac() -> Platform {
        Platform(
            presence: MacPresence(), files: FilePanels(), pasteboard: ClipboardPasteboard(),
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

extension MediaPlayback: Playback {}

extension WebPane: WebPresenting {}

/// Calls over LiveKit, each a `CallSession`.
struct LiveKitCalls: CallProvider {
    func join(_ ticket: CallTicket, link: CallLink, chat: String, title: String, camera: Bool) -> any OngoingCall {
        CallSession(ticket: ticket, link: link, chat: chat, title: title, camera: camera)
    }
}

extension CallSession: OngoingCall {}

extension CallStore {
    /// The call you are on, with its media, for the call window and the
    /// sidebar's bar.
    var session: CallSession? { call as? CallSession }
}

extension AppModel {
    /// The web pane beside the chat: on the Mac, always a `WebPane`
    /// (`Platform.mac()`).
    var web: WebPane { webPresenter as! WebPane }
}
