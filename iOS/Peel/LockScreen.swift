import PeelCore
import PeelUI
import SwiftUI

/// Asks for the PIN at launch (the Mac's `LockView`).
struct LockScreen: View {
    @Environment(AppModel.self) private var model
    @State private var pin = ""
    @State private var working = false
    @State private var problem: String?
    /// Whether the account is known to hold sats, for Forget; never how
    /// many (`AppModel.balanceBeforeForget`).
    @State private var holdsSats = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                AppIcon(size: 72)
                VStack(spacing: Theme.Space.sm) {
                    Text("Enter your PIN")
                        .font(Theme.font(28, .bold))
                    Text(problem ?? " ")
                        .font(Theme.font(15))
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                PinBoxes(pin: $pin) { Task { await unlock() } }
                    .disabled(working)
                ProgressView()
                    .opacity(working ? 1 : 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 72)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // For a lost PIN.
            ForgetAccount(
                trigger: "Forgot your PIN?",
                explanation: holdsSats
                    ? "Forget this account on this iPhone. It holds sats. Without your twelve words, they're lost for good."
                    : "Forget this account on this iPhone. Without your twelve words, it can't be brought back."
            )
            // Not while an unlock is opening the account.
            .disabled(working)
            .padding(.horizontal, 20)
            .padding(.bottom, Theme.Space.md)
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .task { holdsSats = await (model.balanceBeforeForget() ?? 0) > 0 }
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

/// Removes the account from this iPhone (`AppModel.forgetAccount`),
/// confirmed in place under its trigger with what is lost, never in a
/// dialog, as on the Mac.
struct ForgetAccount: View {
    @Environment(AppModel.self) private var model
    let trigger: String
    let explanation: String

    @State private var confirming = false
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            if confirming {
                Text(explanation)
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.md) {
                    Button { confirming = false } label: { ActionLabel("Cancel") }
                        .secondaryAction()
                    Button(role: .destructive) { Task { await forget() } } label: {
                        ActionLabel("Forget account", working: working)
                    }
                    .secondaryAction()
                    .tint(Theme.destructive)
                }
            } else {
                Button(trigger) { confirming = true }
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.secondaryText)
            }
            if let problem { ProblemText(problem) }
        }
        .frame(maxWidth: .infinity)
    }

    private func forget() async {
        guard !working else { return }
        working = true
        defer { working = false }
        problem = nil
        do { try await model.forgetAccount() } catch { problem = PeelError.problem(error, couldNot: "forget the account") }
    }
}
