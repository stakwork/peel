import PeelCore
import PeelUI
import SwiftUI

/// The phone's money button: the Mac's `PayButton` two-step, made safe for
/// a finger. The first tap asks the engine (`PaymentAttempt`); over the
/// confirmation amount it answers with the amount, and the button gives way
/// to Cancel and an orange "Send 2,000 sats" that wakes only after a
/// moment, so a double tap can never be the confirmation. That second tap
/// sends exactly the amount shown (the engine refuses any other). A change
/// to the amount puts it back. A success haptic once sent.
struct TouchPayButton: View {
    /// "Pay", "Send", "Save".
    let verb: String
    /// The total as it stands; nil while the amount is not valid.
    let totalMsat: UInt64?
    let attempt: PaymentAttempt
    let send: (_ confirmedMsat: UInt64?) async -> PaymentOutcome
    var sent: () -> Void = {}

    /// The armed button takes taps only once this has passed.
    static let settle: Duration = .milliseconds(700)

    @State private var ready = false
    @State private var sentCount = 0

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            if let armed = attempt.armed {
                Text("That's over your confirmation amount. Check it, then confirm.")
                    .phoneFont(.secondary)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.md) {
                    Button { attempt.armed = nil } label: { Text("Cancel").frame(maxWidth: .infinity) }
                        .buttonStyle(.peel(.outline, size: .touch))
                        .disabled(attempt.working)
                    Button { run() } label: {
                        Text("\(verb) \(Sats.format(msat: armed))")
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                            .buttonProgress(attempt.working)
                    }
                    .buttonStyle(.peel(.primary, size: .touch, fill: Theme.attention))
                    .disabled(!ready)
                    .accessibilityHint("Sends \(Sats.format(msat: armed))")
                }
            } else {
                Button { run() } label: {
                    Text(verb).frame(maxWidth: .infinity).buttonProgress(attempt.working)
                }
                .buttonStyle(.peel(.primary, size: .touch))
                // Not off while it sends, so it keeps its fill under the
                // spinner; `PaymentAttempt.run` ignores a second tap.
                .disabled(totalMsat == nil)
            }
            if let problem = attempt.problem { ProblemText(problem) }
        }
        .task(id: attempt.armed) {
            ready = false
            guard attempt.armed != nil, (try? await Task.sleep(for: Self.settle)) != nil else { return }
            ready = true
        }
        .onChange(of: totalMsat) { attempt.armed = nil }
        .sensoryFeedback(.success, trigger: sentCount)
        .animation(.easeOut(duration: 0.2), value: attempt.armed)
    }

    private func run() {
        Task {
            if await attempt.run(send) {
                sentCount += 1
                sent()
            }
        }
    }
}

/// A whole number of sats, digits only, on the number pad, with "sats" after it.
struct SatsInput: View {
    let label: String
    @Binding var text: String
    @FocusState.Binding var focused: Bool

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            TextField(label, text: $text, prompt: Text("0"))
                .keyboardType(.numberPad)
                .phoneFont(PhoneFont(size: 22, weight: .semibold, style: .title2))
                .monospacedDigit()
                .focused($focused)
            Text("sats")
                .phoneFont(.row)
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(minHeight: 52)
        .fieldBox(focused: focused)
        .onChange(of: text) { _, value in
            let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(12))
            if digits != value { text = digits }
        }
    }
}

/// A one-line text field in a box, for a note or a memo.
struct NoteInput: View {
    let label: String
    let prompt: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $text, prompt: Text(prompt))
            .phoneFont(.row)
            .focused($focused)
            .submitLabel(.done)
            .padding(.horizontal, Theme.Space.md)
            .frame(minHeight: 48)
            .fieldBox(focused: focused)
    }
}

/// A field's label over it, as the Mac's `FormItem`.
struct FieldLabel<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .phoneFont(.sectionHeader)
                .foregroundStyle(Theme.tertiaryText)
            content
        }
    }
}

/// "Balance 12,345 sats", quiet, under a payment form.
struct BalanceLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(model.balanceText.map { "Balance \($0)" } ?? "Balance known once connected")
            .phoneFont(.secondary)
            .monospacedDigit()
            .foregroundStyle(Theme.tertiaryText)
    }
}

/// A sheet's page: a title in the bar, Close on the left, the content in a
/// scroll view on the page's colour, and buttons pinned at the bottom.
struct SheetPage<Content: View, Actions: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions
    @Environment(\.dismissSheet) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content }
                .padding(.horizontal, Theme.phoneGutter)
                .padding(.vertical, Theme.Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) { actions }
                .padding(.horizontal, Theme.phoneGutter)
                .padding(.vertical, Theme.Space.md)
                .background(Theme.background)
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", systemImage: "xmark") { dismiss() }
            }
        }
    }
}
