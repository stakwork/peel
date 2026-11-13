import PeelCore
import PeelUI
import SwiftUI

/// Asks for the PIN (the Mac's `LockView`; docs/design/iphone.md, screen 8):
/// the Peel icon, "Enter your PIN", the keypad, and "Forgot your PIN?",
/// which confirms Forget in place. When the lock is Face ID's check within
/// the PIN timeout (`AppModel.lockOffersBiometrics`), no keypad shows: a cover
/// asks for a face as it appears and again from its button, and the system
/// falls back to the device passcode. Past the timeout only the PIN opens Peel.
struct LockScreen: View {
    @Environment(AppModel.self) private var model
    @State private var pin = ""
    @State private var working = false
    @State private var problem: String?
    /// Whether the account is known to hold sats, for Forget; never how
    /// many (`AppModel.balanceBeforeForget`).
    @State private var holdsSats = false

    var body: some View {
        if model.lockOffersBiometrics, let name = model.biometryName {
            biometricCover(name)
        } else {
            pinScreen
        }
    }

    /// Face ID's check while the PIN is not due: the icon and a button, never the keypad.
    private func biometricCover(_ name: String) -> some View {
        VStack(spacing: 28) {
            Spacer()
            AppIcon(size: 64)
                .accessibilityHidden(true)
            VStack(spacing: Theme.Space.sm) {
                Text("Peel is locked")
                    .phoneFont(PhoneFont(size: 20, weight: .bold, style: .title3))
                    .accessibilityAddTraits(.isHeader)
                Text(problem ?? "Unlock with \(name) to continue.")
                    .phoneFont(PhoneFont(size: 15, style: .subheadline))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Task { await useBiometrics() }
            } label: {
                Text("Unlock with \(name)").buttonProgress(working)
            }
            .buttonStyle(.peel(.primary, size: .touch))
            .disabled(working)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, Theme.phoneGutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .task { await useBiometrics() }
    }

    private var pinScreen: some View {
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
                PinPad(pin: $pin) {
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

    /// Face ID's check, with the device passcode as the system's fallback;
    /// cancelled, the cover stays for another try. When the kept PIN is gone
    /// (or wrong), the model drops the check and the keypad asks for the PIN.
    private func useBiometrics() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            if try await !model.unlockWithBiometrics() {
                problem = model.lockOffersBiometrics ? nil : "Enter your PIN."
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
