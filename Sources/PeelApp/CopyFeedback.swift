import SwiftUI

/// What every copy action shows once it has copied: a button's icon turns
/// into a check (green, or the button's text colour on a filled button) and
/// its title into "Copied" for a moment
/// (`CopyButton`, `CopyLabel`); a menu, which has closed by then, shows a
/// "Copied" pill at the bottom of the window (`MenuEntry.copy`, through
/// `MenuPresenter.showToast`). VoiceOver hears "Copied" either way.
enum CopyFeedback {
    /// How long the check or the pill stays.
    static let hold: Duration = .milliseconds(1500)

    /// In quickly, without overshoot; a cross-fade only under Reduce Motion.
    static func enter(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.18, bounce: 0)
    }

    /// Out a little faster than in.
    static let exit: Animation = .easeOut(duration: 0.14)

    @MainActor static func announce(_ text: String = "Copied") {
        AccessibilityNotification.Announcement(text).post()
    }
}
