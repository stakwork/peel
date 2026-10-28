import PeelCore
import PeelUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

// The iPhone's side of `Platform` (the Mac's is `MacPlatform.swift`). What
// it cannot do yet throws or says so, and the views never offer it
// (docs/phases/07-iphone.md, I2); calls are on LiveKit (I6).

extension Platform {
    /// A new set each call: the app makes its one model with it.
    static func phone() -> Platform {
        Platform(
            presence: PhonePresence(), files: PhoneFiles(), pasteboard: ClipboardPasteboard(),
            playback: PhonePlayback(), web: { _ in PhoneWeb() }, calls: LiveKitCalls(), agent: nil,
            // Chats is a list to come back to, not a pane to fill.
            opensFirstChat: false
        )
    }
}

/// Peel among the phone's apps: `UIApplication` and its icon's badge.
struct PhonePresence: AppPresence {
    var isFrontmost: Bool { UIApplication.shared.applicationState == .active }

    /// Not until push (I5): a suspended app posts nothing, so asking for
    /// permission now would promise what does not come.
    var postsNotifications: Bool { false }

    func activate() {}

    func showBadge(_ count: Int) {
        // Shown once notifications are allowed (I5); until then the system ignores it.
        UNUserNotificationCenter.current().setBadgeCount(count, withCompletionHandler: nil)
    }

    func openNotificationSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    /// Notifications here always carry their sound; there is no sound-only style.
    func playSound(named name: String) {}
}

/// No file panels yet: nothing here attaches, saves or picks a photo (I3).
struct PhoneFiles: FilePicking {
    func open(prompt: String?, multiple: Bool, directories: Bool, types: [UTType]) -> [URL]? { nil }
    func saveLocation(named name: String) -> URL? { nil }
    func reveal(_ file: URL) {}
}

/// Video plays in its row (`VideoPlayback`); there is no full-screen viewer
/// of ours, so closing one has nothing to do.
struct PhonePlayback: Playback {
    func play(_ id: Int64, file: URL) { VideoPlayback.shared.play(id, file: file) }
    func closeFullScreen() {}
    func stop() { VideoPlayback.shared.stop() }
}

/// No web pane yet; an HTML attachment says so where it was opened.
final class PhoneWeb: WebPresenting {
    func openDocument(_ file: URL, named name: String) async throws {
        throw PeelError("Pages open on the Mac for now.")
    }

    func forgetWebsiteData() async {}
}

/// Calls over LiveKit, each an `IOSCallSession`.
struct LiveKitCalls: CallProvider {
    func join(_ ticket: CallTicket, link: CallLink, chat: String, title: String, camera: Bool) -> any OngoingCall {
        IOSCallSession(ticket: ticket, link: link, chat: chat, title: title, camera: camera)
    }
}

extension IOSCallSession: OngoingCall {}
