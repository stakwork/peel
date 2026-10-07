import SwiftUI
import PeelCore

/// Asks for the PIN at launch, and again after the PIN timeout.
struct LockView: View {
    @Environment(AppModel.self) private var model
    @State private var pin = ""
    @State private var working = false
    @State private var problem: String?
    @State private var confirmingForget = false

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
                forget
            }
        }
    }

    /// For a lost PIN. Confirmed in place, next to the trigger.
    @ViewBuilder private var forget: some View {
        if confirmingForget {
            VStack(spacing: 10) {
                Text("This removes the account's words and messages from this Mac. You can restore it later with your twelve words.")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                HStack(spacing: 16) {
                    Button("Cancel") { confirmingForget = false }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.secondaryText)
                    Button("Forget account") {
                        Task {
                            do { try await model.forgetAccount() } catch { problem = "\(error)" }
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.destructive)
                }
                .font(Theme.font(13, .medium))
            }
        } else {
            Button("Forgot your PIN? Forget this account on this Mac") { confirmingForget = true }
                .buttonStyle(.plain)
                .font(Theme.font(13))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private func unlock() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            try await model.unlock(pin: pin)
        } catch {
            problem = error as? SecretStoreFailure == .wrongPIN ? "Wrong PIN. Try again." : "\(error)"
            pin = ""
        }
    }
}
