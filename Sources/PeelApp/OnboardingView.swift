import SwiftUI
import PeelCore

/// New account (invite → name → PIN → twelve words) or restore (twelve words →
/// name → PIN → progress). See docs/design/README.md, "Profile and onboarding".
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    private enum Path { case newAccount, restore }
    private enum Step { case welcome, invite, enterWords, name, pin, confirmPin, showWords, restoring }

    @State private var path = Path.newAccount
    @State private var step = Step.welcome
    @State private var invite = ""
    @State private var words = Array(repeating: "", count: 12)
    @State private var name = ""
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var shownWords: [String] = []
    @State private var wroteDown = false
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        OnboardingPage(progress: progress, problem: problem ?? model.notice) {
            switch step {
            case .welcome: welcome
            case .invite: inviteStep
            case .enterWords: enterWordsStep
            case .name: nameStep
            case .pin: pinStep
            case .confirmPin: confirmPinStep
            case .showWords: showWordsStep
            case .restoring: RestoreProgressView()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.usesFileSecrets { FileSecretsBanner() }
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 28) {
            AppIcon(size: 88)
            VStack(spacing: 10) {
                Text("Welcome to Peel")
                    .font(Theme.font(28, .bold))
                Text("Sphinx on your Mac. Private messages, tribes and sats, on an account only you hold the keys to.")
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 10) {
                Button("I have an invite") { path = .newAccount; go(.invite) }
                    .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                Button("Restore from twelve words") { path = .restore; go(.enterWords) }
                    .buttonStyle(SecondaryButtonStyle())
            }
            Text("New to Sphinx? Ask someone already on it for an invite.")
                .font(Theme.font(13))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: 380)
    }

    private var inviteStep: some View {
        StepBody(title: "Paste your invite",
                 detail: "The link or code someone sent you. It creates your account on the Sphinx server, and may come with sats from whoever invited you.") {
            FormItem(label: "Invite") {
                FormTextField(label: "Invite", prompt: "sphinx.chat/?action=i&d=…", text: $invite, axis: .vertical)
            }
        } footer: {
            footer(next: "Continue", enabled: !invite.trimmed.isEmpty) { go(.name) }
        }
    }

    private var enterWordsStep: some View {
        StepBody(title: "Restore from twelve words",
                 detail: "Type them in order, or paste all twelve into the first box. Peel brings back your contacts and message history from the server. Your other devices keep working.",
                 width: 520) {
            WordEntryGrid(words: $words)
        } footer: {
            footer(next: "Continue", enabled: words.allSatisfy { !$0.isEmpty }) {
                // Catch a mistyped word here, not after the name and PIN.
                do {
                    _ = try Engine.validate(mnemonic: words.joined(separator: " "))
                    go(.name)
                } catch {
                    problem = "Those twelve words don't make a valid account. Check each one."
                }
            }
        }
    }

    private var nameStep: some View {
        StepBody(title: "What should people call you?",
                 detail: "Your name goes with your messages, to the people you talk to and in tribes. You can change it later.") {
            FormItem(label: "Name") {
                FormTextField(label: "Name", prompt: "Required", text: $name)
                    .onSubmit { if !name.trimmed.isEmpty { go(.pin) } }
            }
        } footer: {
            footer(next: "Continue", enabled: !name.trimmed.isEmpty) { go(.pin) }
        }
    }

    private var pinStep: some View {
        StepBody(title: "Set a PIN",
                 detail: "Six digits. Peel asks for it when it opens, and it locks your twelve words on this Mac.") {
            PinField(pin: $pin) { go(.confirmPin) }
        } footer: {
            footer(next: "Continue", enabled: pin.count == 6) { go(.confirmPin) }
        }
    }

    private var confirmPinStep: some View {
        StepBody(title: "Enter your PIN again", detail: "To make sure it's the one you meant.") {
            PinField(pin: $confirmation) { Task { await confirmPin() } }
        } footer: {
            footer(next: path == .newAccount ? "Create account" : "Restore",
                   enabled: confirmation.count == 6 && !working) { Task { await confirmPin() } }
        }
    }

    private var showWordsStep: some View {
        StepBody(title: "Write down your twelve words",
                 detail: "They are your account. With them you can restore it on any device; anyone else who has them controls your messages and sats. Peel keeps them locked with your PIN on this Mac and never sends them anywhere.",
                 width: 520) {
            VStack(alignment: .leading, spacing: 18) {
                NumberedWordGrid(count: shownWords.count) { index in
                    Text(shownWords[index])
                        .font(Theme.font(15))
                    Spacer(minLength: 0)
                }
                Toggle("I've written them down somewhere safe, on paper", isOn: $wroteDown)
                    .toggleStyle(.checkbox)
                    .font(Theme.font(14))
            }
        } footer: {
            HStack {
                Spacer()
                Button("Open Peel") {
                    shownWords = []
                    model.enterApp()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!wroteDown)
            }
        }
    }

    // MARK: Actions

    /// The numbered steps of the current path; confirming the PIN counts as the PIN step.
    private var steps: [Step] {
        path == .newAccount ? [.invite, .name, .pin, .showWords] : [.enterWords, .name, .pin]
    }

    private var position: Int? { steps.firstIndex(of: step == .confirmPin ? .pin : step) }

    private var progress: (step: Int, of: Int)? {
        position.map { ($0 + 1, steps.count) }
    }

    /// Moves to a step, clearing the last step's problem.
    private func go(_ next: Step) {
        problem = nil
        step = next
    }

    private func back() {
        if step == .confirmPin {
            confirmation = ""
            go(.pin)
        } else if let position, position > 0 {
            go(steps[position - 1])
        } else {
            // Leaving the flow forgets what was typed; stepping back within it keeps it.
            invite = ""
            words = Array(repeating: "", count: 12)
            go(.welcome)
        }
    }

    private func confirmPin() async {
        guard !working, confirmation.count == 6 else { return }
        guard confirmation == pin else {
            pin = ""
            confirmation = ""
            go(.pin)
            problem = "The PINs don't match. Set it again."
            return
        }
        working = true
        defer { working = false }
        do {
            switch path {
            case .newAccount:
                shownWords = try await model.createAccount(invite: invite, name: name.trimmed, pin: pin)
                go(.showWords)
            case .restore:
                try await model.restoreAccount(words: words, name: name.trimmed, pin: pin)
                words = Array(repeating: "", count: 12)
                go(.restoring)
            }
            pin = ""
            confirmation = ""
        } catch {
            problem = PeelError.readable(error)
            confirmation = ""
        }
    }

    private func footer(next: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Button("Back", action: back)
                .buttonStyle(.plain)
                .font(Theme.font(14))
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            Button(action: action) { Text(next).buttonProgress(working) }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!enabled)
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// Contacts, then messages, as the server sends them back.
struct RestoreProgressView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let progress = model.restoreProgress
        StepBody(title: "Restoring your account",
                 detail: "A busy account takes a few minutes. You can start using Peel now; older history keeps arriving in the background.",
                 width: 460) {
            VStack(spacing: 0) {
                RestoreRow(title: "Account", detail: model.connection.label,
                           state: model.connection == .connected ? .done : .active)
                RestoreRow(title: "Contacts", detail: describe(progress.contacts, noun: "checked"),
                           state: .from(started: progress.contacts != nil, done: progress.messages != nil || progress.finished))
                RestoreRow(title: "Messages", detail: describe(progress.messages, noun: "received"),
                           state: .from(started: progress.messages != nil, done: progress.finished),
                           fraction: progress.messages?.fraction)
            }
            .formCard()
            if case .failed(let failure) = progress.outcome {
                Text(failure)
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.secondaryText)
            }
        } footer: {
            HStack {
                Spacer()
                Button("Open Peel") { model.enterApp() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func describe(_ count: AppModel.RestoreProgress.Count?, noun: String) -> String {
        guard let count else { return model.restoreProgress.finished ? "None" : "Waiting" }
        if let end = count.end { return "\(count.reached.formatted()) of \(end.formatted())" }
        return "\(count.reached.formatted()) \(noun)"
    }
}

struct RestoreRow: View {
    enum State {
        case waiting, active, done

        static func from(started: Bool, done: Bool) -> State {
            done ? .done : started ? .active : .waiting
        }
    }
    let title: String
    let detail: String
    let state: State
    var fraction: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                case .active:
                    ProgressView().controlSize(.small)
                case .waiting:
                    Image(systemName: "circle").foregroundStyle(Theme.divider)
                }
            }
            .font(.system(size: 18))
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(Theme.font(14))
                        .foregroundStyle(state == .waiting ? Theme.secondaryText : Theme.text)
                    Spacer()
                    Text(detail)
                        .font(Theme.font(12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                }
                if let fraction, state == .active {
                    ProgressView(value: fraction)
                        .tint(Theme.accent)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Theme.divider.frame(height: 1) }
    }
}

// MARK: - Building blocks

/// The dark full-window page every onboarding step sits on.
struct OnboardingPage<Content: View>: View {
    var progress: (step: Int, of: Int)?
    var problem: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 22) {
            if let progress {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        ForEach(1...progress.of, id: \.self) { index in
                            Capsule()
                                .fill(index <= progress.step ? Theme.accent : Theme.divider)
                                .frame(height: 3)
                        }
                    }
                    Text("Step \(progress.step) of \(progress.of)")
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: 440)
            }
            content
            if let problem {
                Text(problem)
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: 440, alignment: .leading)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .endsEditingOnClick()
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.text)
    }
}

/// Title, explanation, the step's fields and its buttons.
struct StepBody<Fields: View, Footer: View>: View {
    let title: String
    let detail: String
    var width: CGFloat = 440
    @ViewBuilder let fields: Fields
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(Theme.font(24, .bold))
                Text(detail)
                    .font(Theme.font(14))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            fields
            footer
        }
        .frame(maxWidth: width)
    }
}

/// Three columns of numbered boxes, for showing or typing the twelve words:
/// the form's boxed fields, the one being typed in (`focused`) ringed.
struct NumberedWordGrid<Cell: View>: View {
    let count: Int
    var focused: Int?
    @ViewBuilder let cell: (Int) -> Cell

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                HStack(spacing: 10) {
                    Text("\(index + 1)")
                        .font(Theme.font(12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 18, alignment: .trailing)
                    cell(index)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .modifier(FieldChrome(focused: focused == index))
            }
        }
    }
}

/// Twelve boxes to type into. Pasting all twelve words into any box, or with
/// the button, spreads them out.
struct WordEntryGrid: View {
    @Binding var words: [String]
    @FocusState private var focus: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                if let text = Clipboard.paste() {
                    focus = nil
                    fill(from: 0, with: text)
                }
            } label: {
                Label("Paste twelve words", systemImage: "doc.on.clipboard")
                    .font(Theme.font(13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            NumberedWordGrid(count: 12, focused: focus) { index in
                TextField("", text: binding(for: index))
                    .focused($focus, equals: index)
                    .textFieldStyle(.plain)
                    .font(Theme.font(15))
                    .autocorrectionDisabled()
            }
        }
    }

    private func binding(for index: Int) -> Binding<String> {
        Binding {
            words[index]
        } set: { text in
            if fill(from: index, with: text) {
                // The box being edited keeps showing the pasted text until it
                // loses focus; move on at once so every box shows its own word.
                focus = words.firstIndex(where: \.isEmpty)
            }
        }
    }

    /// Puts each word of `text` in its own box, starting at `index`. Returns
    /// whether the text held more than one word. Twelve words pasted from
    /// the clipboard leave it once read.
    @discardableResult
    private func fill(from index: Int, with text: String) -> Bool {
        let parts = Engine.words(in: text)
        guard parts.count > 1 else {
            words[index] = parts.first ?? ""
            return false
        }
        for (offset, part) in parts.prefix(12 - index).enumerated() {
            words[index + offset] = part
        }
        Clipboard.clearPasted(words: parts)
        return true
    }
}

/// Six boxes over a hidden secure field, so the digits are never shown.
struct PinField: View {
    @Binding var pin: String
    let complete: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            SecureField("", text: $pin)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .focused($focused)
                .opacity(0.01)
                .accessibilityLabel("PIN")
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    // The form's boxed field; the next digit's box ringed.
                    Color.clear
                        .frame(height: 52)
                        .modifier(FieldChrome(focused: focused && index == pin.count))
                        .overlay {
                            if index < pin.count {
                                Circle().fill(Theme.text).frame(width: 10, height: 10)
                            }
                        }
                }
            }
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .task {
            // Focus asked for during the screen change is ignored; ask once it has settled.
            try? await Task.sleep(for: .milliseconds(150))
            focused = true
        }
        .onChange(of: pin) { _, value in
            let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(PIN.length))
            if digits != value { pin = digits }
            if digits.count == 6 { complete() }
        }
    }
}
