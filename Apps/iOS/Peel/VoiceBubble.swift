import PeelCore
import PeelUI
import SwiftUI

/// A voice message in a row on the phone: the shared controls in a card.
struct VoiceBubble: View {
    let message: Message

    var body: some View {
        PhoneCard {
            VoiceControls(message: message)
                .padding(.horizontal, Theme.Space.sm)
                .padding(.vertical, 4)
        }
        .frame(maxWidth: 280, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voice message")
    }
}
