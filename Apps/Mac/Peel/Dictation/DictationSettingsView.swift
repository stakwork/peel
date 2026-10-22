import AppKit
import SwiftUI
import PeelUI

/// Account › Dictation: on or off, the key, and what macOS has been asked for.
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
            } trailing: {
                HotkeyRecorder(current: dictation.hotkey) { dictation.setHotkey($0) }
            }
            DictationPermissionRows(permissions: dictation.permissions)
            Text("macOS may ask you to restart Peel after you allow Input Monitoring. "
                + "To use Fn, set System Settings › Keyboard › Press 🌐 key to Do Nothing.")
                .muted()
                .fixedSize(horizontal: false, vertical: true)
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

/// Press a key to choose it: a modifier on its own (Right Option, Fn …) or
/// any other key. Escape stops choosing.
private struct HotkeyRecorder: View {
    let current: HotkeyConfig
    let choose: (HotkeyConfig) -> Void
    @State private var recording = false
    @State private var monitor: Any?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button(recording ? "Press a key…" : "Change") { recording ? stop() : start() }
                .buttonStyle(.peel(.outline))
            if let problem { Text(problem).muted() }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        problem = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            if event.type == .keyDown, event.keyCode == 53 {
                stop()
                return nil
            }
            let key = HotkeyConfig.key(code: event.keyCode, character: event.charactersIgnoringModifiers)
            if event.type == .flagsChanged {
                // Only the press of a modifier counts, not its release.
                guard key.isModifier, key.isDown(flags: UInt64(event.modifierFlags.rawValue)) == true else { return nil }
            } else if event.isARepeat {
                return nil
            }
            if key.isReserved {
                problem = "Space and Escape are used while dictating."
            } else {
                choose(key)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

/// Offered once, at the foot of the window, until dictation's permissions are in
/// or the offer is turned down.
struct DictationOffer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "mic")
                .foregroundStyle(Theme.secondaryText)
            Text("Dictate anywhere on your Mac by holding a key?")
                .font(Theme.font(13))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                Button("Not now") { DictationController.shared.dismissOffer() }
                    .buttonStyle(.peel(.outline, size: .sm))
                Button("Set up") {
                    DictationController.shared.dismissOffer()
                    model.destination = .account
                }
                .buttonStyle(.peel(.primary, size: .sm))
            }
            .fixedSize()
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, 10)
        .background(Theme.panel)
        .overlay(alignment: .top) { Theme.divider.frame(height: 1) }
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
