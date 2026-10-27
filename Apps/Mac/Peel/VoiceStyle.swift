import SwiftUI

/// What the shared voice views take from the Mac: its control height and
/// its type (`Apps/Shared/Voice`).
enum VoiceStyle {
    static let target = PeelButton.Size.sm.height
    static let indicatorInset: CGFloat = 8
}

extension View {
    /// The small line under a voice message's bar.
    func voiceCaption() -> some View { font(Theme.font(11)) }
    /// A word of help in the composer.
    func voiceNote() -> some View { font(Theme.font(12)) }
}
