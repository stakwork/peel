import PeelCore
import SwiftUI

/// The PIN as the lock screen asks for it (docs/design/iphone.md, screen 8):
/// six dots filled as digits go in, then a 3 by 4 keypad of 78 pt round
/// keys, Face ID bottom left (when it is on) and Delete bottom right. Calls
/// `complete` at the sixth digit; the caller clears `pin` after a refusal.
/// The lock screen, Change PIN, the words and Face ID's switch share it.
struct PinPad: View {
    @Binding var pin: String
    /// Face ID's key, when it is on; nil leaves its place empty.
    var biometry: (name: String, action: () -> Void)?
    let complete: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .title) private var digit: CGFloat = 30

    private static let key: CGFloat = 78

    var body: some View {
        VStack(spacing: 44) {
            PinDots(count: pin.count)
            Grid(horizontalSpacing: 26, verticalSpacing: 18) {
                ForEach([["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]], id: \.self) { row in
                    GridRow { ForEach(row, id: \.self) { digitKey($0) } }
                }
                GridRow {
                    if let biometry {
                        symbolKey(biometry.name == "Touch ID" ? "touchid" : "faceid", label: "Use \(biometry.name)",
                                  action: biometry.action)
                    } else {
                        Color.clear.frame(width: Self.key, height: Self.key)
                    }
                    digitKey("0")
                    symbolKey("delete.left", label: "Delete") { if !pin.isEmpty { pin.removeLast() } }
                        .opacity(pin.isEmpty ? 0.35 : 1)
                }
            }
        }
        .opacity(isEnabled ? 1 : 0.6)
        .sensoryFeedback(.selection, trigger: pin.count)
    }

    private func digitKey(_ digit: String) -> some View {
        Button {
            guard pin.count < PIN.length else { return }
            pin.append(digit)
            if pin.count == PIN.length { complete() }
        } label: {
            Text(digit)
                .font(.system(size: self.digit))
                .monospacedDigit()
                .frame(width: Self.key, height: Self.key)
                .background(Theme.fieldFill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(KeyStyle())
    }

    private func symbolKey(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .frame(width: Self.key, height: Self.key)
                .contentShape(Circle())
        }
        .buttonStyle(KeyStyle())
        .accessibilityLabel(label)
    }
}

/// A key lit while pressed, instantly, as the system's passcode keys are.
private struct KeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.text)
            .background(configuration.isPressed ? Theme.text.opacity(0.18) : .clear, in: Circle())
    }
}

/// Six dots, `count` of them filled; VoiceOver reads "2 of 6 digits entered".
struct PinDots: View {
    let count: Int

    var body: some View {
        HStack(spacing: 16) {
            ForEach(0..<PIN.length, id: \.self) { index in
                Circle()
                    .strokeBorder(index < count ? Theme.text : Theme.secondaryText, lineWidth: 1.5)
                    .background(index < count ? Theme.text : .clear, in: Circle())
                    .frame(width: 14, height: 14)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PIN")
        .accessibilityValue("\(count) of \(PIN.length) digits entered")
    }
}

/// A screen that asks for the PIN on the keypad: the title, a line under
/// it (a refusal, or what the PIN is for), and the pad; Cancel when given.
struct PinPrompt: View {
    let title: String
    var detail: String?
    @Binding var pin: String
    var working = false
    var biometry: (name: String, action: () -> Void)?
    let complete: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: Theme.Space.sm) {
                    Text(title)
                        .phoneFont(PhoneFont(size: 20, weight: .bold, style: .title3))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(detail ?? " ")
                        .phoneFont(PhoneFont(size: 15, style: .subheadline))
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PinPad(pin: $pin, biometry: biometry, complete: complete)
                    .disabled(working)
                ProgressView().opacity(working ? 1 : 0)
            }
            .padding(.horizontal, Theme.phoneGutter)
            .padding(.top, Theme.Space.xl)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.text)
    }
}
