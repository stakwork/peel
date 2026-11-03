import UIKit

/// Which orientations the app may rotate to right now. The project allows
/// portrait and both landscapes; this narrows that to portrait everywhere
/// except the chat, which is the only screen laid out for landscape. The call
/// screen stays portrait even over a chat: its grid and focused-tile strip
/// are not landscape-ready.
@MainActor
final class OrientationLock {
    static let shared = OrientationLock()

    /// A `ConversationScreen` is on screen (sheets and covers over it do not
    /// clear this, so the viewers over a chat may rotate).
    var chatVisible = false
    /// The call screen is presented.
    var callShown = false

    var mask: UIInterfaceOrientationMask {
        chatVisible && !callShown ? .allButUpsideDown : .portrait
    }

    /// What `PeelAppDelegate` answers with.
    nonisolated static var mask: UIInterfaceOrientationMask {
        MainActor.assumeIsolated { shared.mask }
    }

    /// Recomputes the mask and, so leaving the chat or opening a call turns
    /// the screen back upright, asks the active scene to rotate into it.
    func update() {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let scene else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        if #available(iOS 16.0, *) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }
    }
}
