import AppKit
import SwiftUI
import PeelUI

/// Account › Dictation: on or off, the key (Right Option for now), and what macOS has been asked for.
struct DictationSettingsSection: View {
    private var dictation: DictationController { .shared }

    var body: some View {
        SettingsSection("Dictation") {
            Fact("Dictation") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(stateText)
                    if let note { Text(note).muted() }
                }
            } trailing: {
                Toggle("Dictation", isOn: Binding(get: { dictation.isEnabled }, set: { dictation.setEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            Fact("Key") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dictation.hotkey.label)
                    Text("Hold to dictate, let go to finish. Press Space while holding to keep going hands-free.").muted()
                }
            }
            DictationPermissionRows(permissions: dictation.permissions)
        }
        .onAppear { dictation.refresh() }
    }

    private var stateText: String {
        if !dictation.isEnabled { return "Off" }
        if !dictation.permissions.requiredGranted { return "Waiting for permissions" }
        return dictation.isListening ? "On" : "Starting…"
    }

    private var note: String? {
        if dictation.secureInput { return "Another app is blocking keyboard shortcuts (secure input), so the key may not work." }
        if dictation.isListening && !dictation.canSwallow {
            return "Without Accessibility, the Space that keeps dictation going also types a space."
        }
        return nil
    }
}

/// Offered once, at the foot of the window, until dictation's permissions are in
/// or the offer is turned down.
struct DictationOffer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        OfferBar(
            icon: "mic", text: "Dictate anywhere on your Mac by holding a key?", action: "Set up",
            dismiss: { DictationController.shared.dismissOffer() },
            accept: {
                DictationController.shared.dismissOffer()
                model.destination = .account
            }
        )
    }
}

/// The app menu's line for dictation: its state, and a way to turn it off or on.
struct DictationMenuItem: View {
    var body: some View {
        let dictation = DictationController.shared
        Button(dictation.isEnabled ? "Turn Dictation Off" : "Turn Dictation On") {
            dictation.setEnabled(!dictation.isEnabled)
        }
        Text("Dictation: " + (dictation.isListening ? "On (\(dictation.hotkey.label))" : "Off"))
    }
}
