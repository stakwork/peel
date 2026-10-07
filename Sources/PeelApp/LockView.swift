import SwiftUI
import PeelCore

/// Asks for the PIN at launch, and again after the PIN timeout.
struct LockView: View {
    @Environment(AppModel.self) private var model
    @State private var pin = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        OnboardingPage(progress: nil, problem: nil) {
            VStack(spacing: 24) {
                #if os(macOS)
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                #endif
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
            }
        }
    }

    private func unlock() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            try await model.unlock(pin: pin)
        } catch SecretStoreFailure.wrongPIN {
            problem = "Wrong PIN. Try again."
            pin = ""
        } catch {
            problem = "\(error)"
            pin = ""
        }
    }
}
