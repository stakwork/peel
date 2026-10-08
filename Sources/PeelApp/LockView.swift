import SwiftUI
import PeelCore

/// Asks for the PIN at launch, and again after the PIN timeout.
struct LockView: View {
    @Environment(AppModel.self) private var model
    @State private var pin = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        OnboardingPage {
            VStack(spacing: 24) {
                AppIcon(size: 72)
                VStack(spacing: 8) {
                    Text("Enter your PIN")
                        .font(Theme.font(24, .bold))
                    Text(problem ?? "It unlocks your account on this Mac.")
                        .font(Theme.font(14))
                        .foregroundStyle(Theme.secondaryText)
                }
                PinField(pin: $pin) { Task { await unlock() } }
                    .disabled(working)
                    .frame(maxWidth: 360)
                ProgressView()
                    .controlSize(.small)
                    .opacity(working ? 1 : 0)
                // For a lost PIN.
                ForgetAccountControl(
                    trigger: "Forgot your PIN? Forget this account on this Mac",
                    explanation: "This removes the account's words and messages from this Mac. You can restore it later with your twelve words."
                )
                .frame(maxWidth: 360)
            }
        }
    }

    private func unlock() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            try await model.unlock(pin: pin)
        } catch {
            problem = PIN.problem(error)
            pin = ""
        }
    }
}

extension PIN {
    /// What to show when a PIN was not accepted.
    static func problem(_ error: any Error) -> String {
        error as? SecretStoreFailure == .wrongPIN ? "Wrong PIN. Try again." : PeelError.readable(error)
    }
}

/// Removes the account from this Mac (`AppModel.forgetAccount`), confirmed in
/// place next to the trigger with what is deleted, never in a dialog: a
/// text button on the lock screen, the last section of the Account screen
/// (`section`). Why it failed shows under it.
struct ForgetAccountControl: View {
    @Environment(AppModel.self) private var model
    let trigger: String
    let explanation: String
    var section = false

    @State private var problem: String?

    var body: some View {
        VStack(alignment: section ? .leading : .center, spacing: 8) {
            if section {
                FormDestructiveSection(trigger: trigger, explanation: explanation, confirm: "Forget account", action: forget)
            } else {
                InlineConfirm(
                    trigger: trigger, explanation: explanation, confirm: "Forget account", style: .text, alignment: .center,
                    action: forget
                )
                .font(Theme.font(13))
                .foregroundStyle(Theme.secondaryText)
            }
            if let problem { ProblemText(problem).padding(.horizontal, section ? 4 : 0) }
        }
    }

    private func forget() async {
        problem = nil
        do { try await model.forgetAccount() } catch { problem = PeelError.readable(error) }
    }
}
