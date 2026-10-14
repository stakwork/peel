import PeelCore
import PeelUI
import SwiftUI
import UIKit

// The pieces the phone's onboarding, lock screen and Account share: the PIN
// boxes, the numbered word boxes and a step's page. The Mac's are in
// `OnboardingView.swift` and `FormKit.swift`, over AppKit's fields.

/// A step: its title, an optional line under it, what it asks for, and its
/// buttons pinned at the bottom, clear of the keyboard and the home bar.
struct StepPage<Content: View, Actions: View>: View {
    let title: String
    var detail: String?
    var progress: (step: Int, of: Int)?
    var problem: String?
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let progress { StepProgress(step: progress.step, of: progress.of) }
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text(title)
                        .font(Theme.font(28, .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail)
                            .font(Theme.font(16))
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                content
                if let problem { ProblemText(problem) }
            }
            .padding(.horizontal, 20)
            .padding(.top, Theme.Space.sm)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) { actions }
                .padding(.horizontal, 20)
                .padding(.top, Theme.Space.sm)
                .padding(.bottom, Theme.Space.md)
                .background(Theme.background)
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.text)
    }
}

/// "Step 2 of 3", over a bar of as many pieces.
struct StepProgress: View {
    let step: Int
    let of: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: 6) {
                ForEach(1...of, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? Theme.accent : Theme.divider)
                        .frame(height: 3)
                }
            }
            Text("Step \(step) of \(of)")
                .font(Theme.font(13))
                .foregroundStyle(Theme.secondaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step) of \(of)")
    }
}

/// Why something was not done: secondary text, never red (docs/design).
struct ProblemText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.font(14))
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// A step's main button: full width, filled.
    func primaryAction() -> some View {
        buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(Theme.button)
            .foregroundStyle(Theme.buttonText)
    }

    /// A step's other button: full width, quiet.
    func secondaryAction() -> some View {
        buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
    }

    /// A boxed field, its border ringed in the accent while it has the cursor.
    func fieldBox(focused: Bool) -> some View {
        background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(focused ? Theme.accent : Theme.inputBorder, lineWidth: focused ? 1.5 : 1)
            }
    }
}

/// A full-width label for `primaryAction` and `secondaryAction`, with a
/// spinner in place of the words while it works.
struct ActionLabel: View {
    let title: String
    var working = false

    init(_ title: String, working: Bool = false) {
        self.title = title
        self.working = working
    }

    var body: some View {
        ZStack {
            Text(title).opacity(working ? 0 : 1)
            if working { ProgressView() }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Six boxes over a hidden secure field on the number pad, so the digits
/// are never shown. Calls `complete` at the sixth, once per six typed;
/// focused again when enabled again (after a wrong PIN was checked).
struct PinBoxes: View {
    @Binding var pin: String
    let complete: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ZStack {
            SecureField("", text: $pin)
                .keyboardType(.numberPad)
                .focused($focused)
                .opacity(0.01)
                .accessibilityLabel("PIN")
            HStack(spacing: Theme.Space.sm) {
                ForEach(0..<PIN.length, id: \.self) { index in
                    Color.clear
                        .frame(height: 56)
                        .fieldBox(focused: focused && index == pin.count)
                        .overlay {
                            if index < pin.count {
                                Circle().fill(Theme.text).frame(width: 12, height: 12)
                            }
                        }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .task {
            // Focus asked for while the screen slides in is dropped; ask once it has.
            try? await Task.sleep(for: .milliseconds(450))
            focused = true
        }
        .onChange(of: pin) { old, value in
            let digits = Self.digits(value)
            if digits != value { pin = digits }
            // A seventh key leaves the same six, already complete.
            if digits.count == PIN.length, digits != Self.digits(old) { complete() }
        }
        .onChange(of: isEnabled) { _, enabled in if enabled { focused = true } }
    }

    private static func digits(_ text: String) -> String {
        String(text.filter { $0.isASCII && $0.isNumber }.prefix(PIN.length))
    }
}

/// Two columns of numbered boxes, for showing or typing the twelve words.
/// Each box is numbered with its word's place in `places` (0 to 11).
struct NumberedWords<Cell: View>: View {
    let places: [Int]
    var focused: Int?
    @ViewBuilder let cell: (Int) -> Cell
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
            ForEach(places.indices, id: \.self) { index in
                HStack(spacing: 10) {
                    Text("\(places[index] + 1)")
                        .font(Theme.font(13))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 20, alignment: .trailing)
                    cell(index)
                }
                .padding(.horizontal, Theme.Space.md)
                .frame(height: 48)
                .fieldBox(focused: focused == index)
            }
        }
        // Covered while Peel is not active, so the app switcher's snapshot
        // never holds the words.
        .overlay {
            if scenePhase != .active { Theme.background }
        }
    }
}

extension View {
    /// A word typed into a box: never capitalised, corrected or suggested.
    func wordField() -> some View {
        font(Theme.font(16))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .textContentType(nil)
            .privacySensitive()
    }
}

/// Twelve boxes to type into. Pasting all twelve words into any box, or
/// with the paste button, spreads them out.
struct WordEntry: View {
    @Binding var words: [String]
    @FocusState private var focus: Int?
    /// Bumped when the clipboard may have changed, so the paste button
    /// looks at it again: it decides whether it is enabled only as it appears.
    @State private var clipboardChanges = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            // The system's paste button reads the clipboard without asking.
            PasteButton(payloadType: String.self) { texts in
                guard let text = texts.first else { return }
                focus = nil
                fill(from: 0, with: text)
            }
            .buttonBorderShape(.capsule)
            .labelStyle(.titleAndIcon)
            .id(clipboardChanges)
            // Changed here, or (no notification for that) in another app
            // while Peel was away.
            .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
                clipboardChanges += 1
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                clipboardChanges += 1
            }
            NumberedWords(places: Array(words.indices), focused: focus) { index in
                TextField("", text: binding(for: index))
                    .wordField()
                    .focused($focus, equals: index)
                    .submitLabel(index == words.count - 1 ? .done : .next)
                    .onSubmit { focus = index + 1 < words.count ? index + 1 : nil }
            }
        }
    }

    private func binding(for index: Int) -> Binding<String> {
        Binding {
            words[index]
        } set: { text in
            if fill(from: index, with: text) {
                focus = words.firstIndex(where: \.isEmpty)
            }
        }
    }

    /// Puts each word of `text` in its own box, starting at `index`. Returns
    /// whether the text held more than one word.
    @discardableResult
    private func fill(from index: Int, with text: String) -> Bool {
        let parts = Engine.words(in: text)
        guard parts.count > 1 else {
            words[index] = parts.first ?? ""
            return false
        }
        for (offset, part) in parts.prefix(words.count - index).enumerated() {
            words[index + offset] = part
        }
        if parts.count >= 12 {
            // Twelve words pasted leave the clipboard once read, as on the
            // Mac (`Clipboard.clearPasted`), without reading it again: on the
            // phone a read the person did not start asks them first.
            UIPasteboard.general.items = []
        }
        return true
    }
}

/// The three boxes of a `WordCheck`, each numbered with its word's place.
/// Return moves to the next box, and from the last submits.
struct WordCheckBoxes: View {
    @Binding var check: WordCheck
    let submit: () -> Void
    @FocusState private var focus: Int?

    var body: some View {
        NumberedWords(places: check.positions, focused: focus) { index in
            TextField("", text: $check.answers[index])
                .wordField()
                .focused($focus, equals: index)
                .submitLabel(index + 1 < check.positions.count ? .next : .done)
                .onSubmit { if index + 1 < check.positions.count { focus = index + 1 } else { submit() } }
        }
        .task(id: check.positions) {
            try? await Task.sleep(for: .milliseconds(450))
            focus = 0
        }
    }
}
