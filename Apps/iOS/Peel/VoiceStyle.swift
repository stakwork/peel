import SwiftUI

/// What the shared voice views take from the phone: its touch target and
/// its scaled type (`Apps/Shared/Voice`).
enum VoiceStyle {
    static let target = Theme.touchTarget
    static let indicatorInset: CGFloat = 16
}

extension View {
    /// The small line under a voice message's bar.
    func voiceCaption() -> some View { phoneFont(.time) }
    /// A word of help in the composer.
    func voiceNote() -> some View { phoneFont(.secondary) }
}
