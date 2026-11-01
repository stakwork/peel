import AppIntents
import Observation
import PeelUI

/// Where text from outside the UI (the Action button, Siri, Shortcuts) waits
/// until `RootView` can send it to the agent's DM. In memory only: never
/// written to disk, so text waiting behind the PIN is gone if Peel quits.
@MainActor @Observable
final class AgentInbox {
    static let shared = AgentInbox()

    private(set) var queue = PendingTexts()

    var count: Int { queue.count }

    func submit(_ text: String) {
        queue.add(text)
    }

    func next() -> String? {
        queue.next()
    }
}

/// "Ask Peel": the message is a String parameter left for the system to ask
/// for (Siri and Shortcuts take it by voice with system dictation), so Peel
/// needs no speech or microphone permission and captures no audio itself.
/// Runs in the app, in front: the account may be locked and the model lives
/// in the app's process. `docs/action-button.md`.
struct AskPeelIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Peel"
    static let description = IntentDescription("Send a message to the Peel agent, spoken or typed.")
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let isDiscoverable = true

    @Parameter(title: "Message", requestValueDialog: "What do you want to ask Peel?")
    var message: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw $message.needsValueError("What do you want to ask Peel?")
        }
        AgentInbox.shared.submit(text)
        return .result(dialog: "Sent to Peel")
    }
}

struct PeelShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskPeelIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Talk to \(.applicationName)",
                "Message \(.applicationName)",
            ],
            shortTitle: "Ask Peel",
            systemImageName: "mic.fill"
        )
    }
}
