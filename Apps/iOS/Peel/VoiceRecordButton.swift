import SwiftUI

/// The mic: hold to record, release to send, slide away to cancel.
struct HoldToRecordButton: View {
    let recorder: VoiceRecorder
    /// Told the file when released to send (or at the maximum length).
    let send: (URL) -> Void

    var body: some View {
        GlassSymbol(systemImage: "mic", label: "Record a voice message",
                    tint: recorder.state.isRecording ? Theme.destructive : Theme.secondaryText)
            .frame(width: Theme.touchTarget, height: Theme.touchTarget)
            .contentShape(Rectangle())
            .holdToRecord(recorder, send: send)
            .accessibilityLabel("Record a voice message")
            .accessibilityHint("Hold to record, release to send")
            .accessibilityAddTraits(.isButton)
    }
}
