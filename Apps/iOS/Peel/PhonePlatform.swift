import PeelCore
import PeelPush
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
            opensFirstChat: false,
            // Face ID's on/off follows the account, as in the official iOS app.
            syncsBiometrics: true,
            // Never `setActive`: the phone gets badge-only pushes while the Mac is in use.
            sendsActiveLease: false,
            // Forget takes the token off the server under the ID it registered with.
            pushAppID: { PushConfig.current?.appID },
            // A catch-up in flight as Peel leaves the front gets a few seconds to finish.
            backgroundWork: PhoneBackgroundWork(),
            suspendsInBackground: true
        )
    }
}

/// Time to finish a catch-up after the app left the front, as the push fetch asks for it
/// (`PushRegistration.fetchOnReceive`): `UIApplication`'s background task.
/// The expiry handler ends the task itself, as UIKit requires (an app that holds one past it is
/// killed); the `end` that comes after, once the work has wound down, then does nothing.
struct PhoneBackgroundWork: BackgroundWork {
    /// Tasks begun and not yet ended.
    @MainActor private static var open: Set<Int> = []

    func begin(name: String, onExpire: @escaping @Sendable () -> Void) -> Int {
        // The handler needs the task's identifier, which `beginBackgroundTask` returns.
        let named = Named()
        let task = UIApplication.shared.beginBackgroundTask(withName: name) {
            onExpire()
            // UIKit calls it on the main thread.
            MainActor.assumeIsolated { Self.finish(named.token) }
        }
        named.token = task.rawValue
        if task != .invalid { Self.open.insert(task.rawValue) }
        return task.rawValue
    }

    private final class Named: @unchecked Sendable {
        var token = UIBackgroundTaskIdentifier.invalid.rawValue
    }

    func end(_ token: Int) { Self.finish(token) }

    private static func finish(_ token: Int) {
        guard open.remove(token) != nil else { return }
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token))
    }
}

/// Peel among the phone's apps: `UIApplication` and its icon's badge.
struct PhonePresence: AppPresence {
    var isFrontmost: Bool { UIApplication.shared.applicationState == .active }

    /// Not until push (I5): a suspended app posts nothing, so asking for
    /// permission now would promise what does not come.
    var postsNotifications: Bool { false }

    func activate() {}

    /// A push's badge stays until Peel is back in front: a background wake
    /// writing the local count over it is what made it jump back.
    var badgeFollowsPushWhileAway: Bool { true }

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

/// Video opens in the full-screen `VideoViewer` (`VideoPlayback`); closing
/// one is the viewer's own dismissal.
struct PhonePlayback: Playback {
    func play(_ id: Int64, file: URL) { VideoPlayback.shared.play(id, file: file) }
    func closeFullScreen() { VideoPlayback.shared.stop() }
    func stop() { VideoPlayback.shared.stop() }
}

/// No web pane yet; an HTML attachment says so where it was opened.
final class PhoneWeb: WebPresenting {
    func openDocument(_ file: URL, named name: String) async throws {
        throw PeelError("Pages open on the Mac for now.")
    }

    func forgetWebsiteData() async {}
}

/// Calls over LiveKit, each an `IOSCallSession`, and Talk calls, each a `TalkSession`.
struct LiveKitCalls: CallProvider {
    func join(_ ticket: CallTicket, link: CallLink, chat: String, title: String, camera: Bool, stay: Bool) -> any OngoingCall {
        IOSCallSession(ticket: ticket, link: link, chat: chat, title: title, camera: camera, stay: stay)
    }

    func talk(_ ticket: TalkTicket, home: TalkHome) -> any TalkMedia {
        TalkSession(ticket: ticket, home: home)
    }
}

extension IOSCallSession: SystemEndingCall {}
