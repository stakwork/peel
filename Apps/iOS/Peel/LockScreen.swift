import PeelCore
import PeelUI
import SwiftUI

/// Asks for the PIN (the Mac's `LockView`; docs/design/iphone.md, screen 8):
/// the Peel icon, "Enter your PIN", the keypad, and "Forgot your PIN?",
/// which confirms Forget in place. When the lock is Face ID's check within
/// the PIN timeout (`AppModel.lockOffersBiometrics`), a face is asked for once
/// as the screen appears, and again from its key; past the timeout only the
/// PIN opens Peel.
struct LockScreen: View {
    @Environment(AppModel.self) private var model
    @State private var pin = ""
    @State private var working = false
    @State private var problem: String?
    @State private var biometry: String?
    /// Whether the account is known to hold sats, for Forget; never how
    /// many (`AppModel.balanceBeforeForget`).
    @State private var holdsSats = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                AppIcon(size: 64)
                    .accessibilityHidden(true)
                VStack(spacing: Theme.Space.sm) {
                    Text("Enter your PIN")
                        .phoneFont(PhoneFont(size: 20, weight: .bold, style: .title3))
                        .accessibilityAddTraits(.isHeader)
                    Text(problem ?? " ")
                        .phoneFont(PhoneFont(size: 15, style: .subheadline))
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PinPad(pin: $pin, biometry: biometryKey) {
                    Task { await unlock() }
                }
                .disabled(working)
                ProgressView().opacity(working ? 1 : 0)
            }
            .padding(.horizontal, Theme.phoneGutter)
            .padding(.top, 56)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ForgetAccount(
                trigger: "Forgot your PIN?",
                explanation: "Forget this account on this iPhone. " + AppModel.forgetWarning(holdsSats: holdsSats)
            )
            // Not while an unlock is opening the account.
            .disabled(working)
            .padding(.horizontal, Theme.phoneGutter)
            .padding(.bottom, Theme.Space.md)
            .background(Theme.background)
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .task {
            holdsSats = await (model.balanceBeforeForget() ?? 0) > 0
        }
        .task {
            guard model.lockOffersBiometrics, let name = model.biometryName else { return }
            biometry = name
            await useBiometrics()
        }
    }

    private var biometryKey: (name: String, action: () -> Void)? {
        guard let biometry else { return nil }
        return (biometry, { Task { await useBiometrics() } })
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

    /// Face ID's check; cancelled or not matched, the keypad stays. When the
    /// kept PIN is gone (or wrong), its key goes and the PIN is asked for.
    private func useBiometrics() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            if try await !model.unlockWithBiometrics(), !model.lockOffersBiometrics {
                biometry = nil
                problem = "Enter your PIN."
            }
        } catch {
            problem = PIN.problem(error)
        }
    }
}

/// Removes the account from this iPhone (`AppModel.forgetAccount`),
/// confirmed in place under its trigger with what is lost, never in a
/// dialog, as on the Mac. The confirm is the only red.
struct ForgetAccount: View {
    @Environment(AppModel.self) private var model
    let trigger: String
    let explanation: String
    var destructiveTrigger = false

    @State private var confirming = false
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            if confirming {
                Text(explanation)
                    .phoneFont(PhoneFont(size: 14, style: .subheadline))
                    .foregroundStyle(Theme.quietText(on: .raised))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.md) {
                    Button("Cancel") { confirming = false }
                        .buttonStyle(.peel(.outline, size: .touch))
                    Button(role: .destructive) { Task { await forget() } } label: {
                        Text("Forget account").buttonProgress(working)
                    }
                    .buttonStyle(.peel(.destructive, size: .touch))
                }
            } else {
                Button(trigger) { confirming = true }
                    .phoneFont(PhoneFont(size: 15, style: .subheadline))
                    .foregroundStyle(destructiveTrigger ? Theme.destructive : Theme.link)
                    .frame(minHeight: Theme.touchTarget)
            }
            if let problem { ProblemText(problem) }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.2), value: confirming)
    }

    private func forget() async {
        guard !working else { return }
        working = true
        defer { working = false }
        problem = nil
        do { try await model.forgetAccount() } catch { problem = PeelError.problem(error, couldNot: "forget the account") }
    }
}
