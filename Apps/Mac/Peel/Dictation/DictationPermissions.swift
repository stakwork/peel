import AppKit
import ApplicationServices
import AVFoundation
import Observation
import SwiftUI
import PeelUI

/// What system-wide dictation needs from macOS, and where the user grants it.
/// Re-read whenever Peel comes to the front, since the grant happens in
/// System Settings.
@MainActor @Observable
final class DictationPermissions {
    enum Status: Equatable { case granted, notAsked, denied }

    private(set) var microphone: Status = .notAsked
    private(set) var inputMonitoring: Status = .notAsked
    private(set) var accessibility: Status = .notAsked

    init() { refresh() }

    func refresh() {
        microphone = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
        // Only asked once: after that the system reports a plain no.
        inputMonitoring = CGPreflightListenEventAccess() ? .granted : (inputMonitoringAsked ? .denied : .notAsked)
        accessibility = AXIsProcessTrusted() ? .granted : .denied
    }

    /// What the hotkey and the capture need. Without Accessibility the tap only
    /// listens, so the Space that locks and the Escape that cancels also reach the app.
    var requiredGranted: Bool { microphone == .granted && inputMonitoring == .granted }

    private var inputMonitoringAsked: Bool {
        get { UserDefaults.standard.bool(forKey: DictationDefaults.askedInputMonitoringKey) }
        set { UserDefaults.standard.set(newValue, forKey: DictationDefaults.askedInputMonitoringKey) }
    }

    func requestMicrophone() async {
        if microphone == .notAsked {
            guard !Offscreen.refuses("a device prompt") else { return }
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refresh()
        } else {
            open("Privacy_Microphone")
        }
    }

    func requestInputMonitoring() {
        if inputMonitoring == .notAsked {
            guard !Offscreen.refuses("a device prompt") else { return }
            inputMonitoringAsked = true
            _ = CGRequestListenEventAccess()
            refresh()
        } else {
            open("Privacy_ListenEvent")
        }
    }

    func requestAccessibility() { open("Privacy_Accessibility") }

    func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The permission rows, in Settings and in the first-use offer.
struct DictationPermissionRows: View {
    let permissions: DictationPermissions

    var body: some View {
        Fact("Microphone") {
            state(permissions.microphone, needed: "Needed to hear you")
        } trailing: {
            button(permissions.microphone) { Task { await permissions.requestMicrophone() } }
        }
        Fact("Input Monitoring") {
            state(permissions.inputMonitoring, needed: "Needed to see the dictation key. Peel may need a restart after you allow it.")
        } trailing: {
            button(permissions.inputMonitoring) { permissions.requestInputMonitoring() }
        }
        Fact("Accessibility") {
            state(permissions.accessibility, needed: "Keeps Space and Esc from reaching the app while you dictate")
        } trailing: {
            button(permissions.accessibility) { permissions.requestAccessibility() }
        }
    }

    private func state(_ status: DictationPermissions.Status, needed: String) -> some View {
        Text(status == .granted ? "Allowed" : needed)
            .foregroundStyle(status == .granted ? Theme.text : Theme.secondaryText)
    }

    @ViewBuilder
    private func button(_ status: DictationPermissions.Status, action: @escaping () -> Void) -> some View {
        if status != .granted {
            Button(status == .notAsked ? "Allow" : "System Settings…", action: action)
                .buttonStyle(.peel(status == .notAsked ? .primary : .outline))
        }
    }
}
