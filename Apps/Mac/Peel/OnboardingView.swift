import SwiftUI
import PeelCore
import PeelUI

/// New account (invite → name → PIN → twelve words) or restore (twelve words →
/// name → PIN → progress). See docs/design/README.md, "Profile and onboarding".
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    private enum Path { case newAccount, restore }
    private enum Step { case welcome, invite, enterWords, name, pin, confirmPin, showWords, checkWords, restoring }

    @State private var path = Path.newAccount
    @State private var step = Step.welcome
    @State private var invite = ""
    @State private var words = Array(repeating: "", count: 12)
    @State private var name = ""
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var shownWords: [String] = []
    /// The three words asked back after "I've written them down"; Back
    /// keeps their places and what was typed.
    @State private var check = WordCheck()
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
            case .checkWords: checkWordsStep
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
                Text("Sphinx messages and sats on your Mac.")
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 10) {
                Button { path = .newAccount; go(.invite) } label: {
                    Text("I have an invite").frame(maxWidth: .infinity)
                }
                .buttonStyle(.peel(.primary, size: .lg))
                Button { path = .restore; go(.enterWords) } label: {
                    Text("Restore from twelve words").frame(maxWidth: .infinity)
                }
                .buttonStyle(.peel(.outline, size: .lg))
            }
            Text("No invite? Ask someone on Sphinx.")
                .font(Theme.font(13))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: 380)
    }

    private var inviteStep: some View {
        StepBody(title: "Paste your invite",
                 detail: "The link or code someone sent you.") {
            FormItem(label: "Invite") {
                FormTextField(label: "Invite", prompt: "sphinx.chat/?action=i&d=…", text: $invite, axis: .vertical)
            }
        } footer: {
            footer(next: "Continue", enabled: !invite.trimmed.isEmpty) { go(.name) }
        }
    }

    private var enterWordsStep: some View {
        StepBody(title: "Restore from twelve words",
                 detail: "Type them in order, or paste all twelve.",
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
        StepBody(title: "What should people call you?") {
            FormItem(label: "Name") {
                FormTextField(label: "Name", prompt: "Required", text: $name)
                    .onSubmit { if !name.trimmed.isEmpty { go(.pin) } }
            }
        } footer: {
            footer(next: "Continue", enabled: !name.trimmed.isEmpty) { go(.pin) }
        }
    }

    private var pinStep: some View {
        StepBody(title: "Set a PIN") {
            PinField(pin: $pin) { go(.confirmPin) }
        } footer: {
            footer(next: "Continue", enabled: pin.count == PIN.length) { go(.confirmPin) }
        }
    }

    private var confirmPinStep: some View {
        StepBody(title: "Enter your PIN again") {
            PinField(pin: $confirmation) { Task { await confirmPin() } }
        } footer: {
            footer(next: path == .newAccount ? "Create account" : "Restore",
                   enabled: confirmation.count == PIN.length && !working) { Task { await confirmPin() } }
        }
    }

    private var showWordsStep: some View {
        StepBody(title: "Write down your twelve words",
                 detail: "Anyone with these words controls your account.",
                 width: 520) {
            VStack(alignment: .leading, spacing: 18) {
                NumberedWordGrid(places: Array(shownWords.indices)) { index in
                    Text(shownWords[index])
                        .font(Theme.font(15))
                    Spacer(minLength: 0)
                }
                if model.myContactInfo == nil {
                    // Signed up, the server's answer not yet in: the engine registers again as it
                    // connects. A refused invite never answers, so the line says what to do.
                    Text("Not confirmed yet. If it stays this way, ask for a new invite.")
                        .font(Theme.font(13))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            HStack {
                Spacer()
                Button("I've written them down") { go(.checkWords) }
                .buttonStyle(.peel(.primary, size: .lg))
            }
        }
    }

    /// Three of the words typed back from paper, so a copy with a word
    /// missed or misspelt is caught while the words can still be read here.
    private var checkWordsStep: some View {
        StepBody(title: "Check what you wrote",
                 detail: "Type these three words from your paper.",
                 width: 520) {
            WordCheckGrid(check: $check) { Task { await checkWords() } }
        } footer: {
            footer(next: "Open Peel", enabled: check.isFilled && !working) { Task { await checkWords() } }
        }
    }

    // MARK: Actions

    /// The numbered steps of the current path; confirming the PIN counts as
    /// the PIN step, checking the words as the words step.
    private var steps: [Step] {
        path == .newAccount ? [.invite, .name, .pin, .showWords] : [.enterWords, .name, .pin]
    }

    private var position: Int? {
        steps.firstIndex(of: step == .confirmPin ? .pin : step == .checkWords ? .showWords : step)
    }

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
        } else if step == .checkWords {
            // The account exists: back to the words, never before them.
            go(.showWords)
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
        guard !working, confirmation.count == PIN.length else { return }
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
            problem = PeelError.problem(error)
            confirmation = ""
        }
    }

    /// Records the words as written down and opens Peel, or says which
    /// places differ.
    private func checkWords() async {
        guard !working, check.isFilled else { return }
        working = true
        defer { working = false }
        do {
            try await model.confirmWords(check.byPosition, of: shownWords)
            shownWords = []
            check = WordCheck()
            model.enterApp()
        } catch {
            problem = PeelError.problem(error)
        }
    }

    private func footer(next: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Button("Back", action: back)
                .buttonStyle(.peel(.ghost, size: .lg))
            Spacer()
            Button(action: action) { Text(next).buttonProgress(working) }
            .buttonStyle(.peel(.primary, size: .lg))
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
                 detail: "You can start now while older messages arrive.",
                 width: 460) {
            Card {
                VStack(spacing: 0) {
                    ForEach(progress.lines(connection: model.connection), id: \.title) { RestoreRow(line: $0) }
                }
            }
            if let failure = progress.paused {
                Text(failure)
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.secondaryText)
            }
        } footer: {
            HStack {
                Spacer()
                Button("Open Peel") { model.enterApp() }
                    .buttonStyle(.peel(.primary, size: .lg))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct RestoreRow: View {
    let line: AppModel.RestoreProgress.Line

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                switch line.state {
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
                    Text(line.title)
                        .font(Theme.font(14))
                        .foregroundStyle(line.state == .waiting ? Theme.secondaryText : Theme.text)
                    Spacer()
                    Text(line.detail)
                        .monospacedDigit()
                        .muted()
                }
                if let fraction = line.fraction, line.state == .active {
                    ProgressView(value: fraction)
                        .tint(Theme.accent)
                }
            }
        }
        .padding(.horizontal, Theme.Space.lg)
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
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    HStack(spacing: 6) {
                        ForEach(1...progress.of, id: \.self) { index in
                            Capsule()
                                .fill(index <= progress.step ? Theme.accent : Theme.divider)
                                .frame(height: 3)
                        }
                    }
                    Text("Step \(progress.step) of \(progress.of)")
                        .muted()
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

/// Title, an optional one-line detail, the step's fields and its buttons.
struct StepBody<Fields: View, Footer: View>: View {
    let title: String
    var detail: String?
    var width: CGFloat = 440
    @ViewBuilder let fields: Fields
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text(title)
                    .font(Theme.font(24, .bold))
                if let detail {
                    Text(detail)
                        .font(Theme.font(14))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            fields
            footer
        }
        .frame(maxWidth: width)
    }
}

/// Three columns of numbered boxes, for showing or typing the twelve words:
/// the form's boxed fields, the one being typed in (`focused`) ringed.
/// Each box is numbered with its word's place in `places` (0 to 11): all
/// twelve, or the three a check asks back.
struct NumberedWordGrid<Cell: View>: View {
    let places: [Int]
    var focused: Int?
    @ViewBuilder let cell: (Int) -> Cell

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.sm), count: 3), spacing: Theme.Space.sm) {
            ForEach(places.indices, id: \.self) { index in
                HStack(spacing: 10) {
                    Text("\(places[index] + 1)")
                        .font(Theme.font(12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 18, alignment: .trailing)
                    cell(index)
                }
                .padding(.horizontal, Theme.Space.md)
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
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Button {
                if let text = Clipboard.paste() {
                    focus = nil
                    fill(from: 0, with: text)
                }
            } label: {
                Label("Paste twelve words", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.peel(.link))
            NumberedWordGrid(places: Array(words.indices), focused: focus) { index in
                TextField("", text: binding(for: index))
                    .focused($focus, equals: index)
                    .wordBox()
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
        guard let parts = WordBoxes.fill(&words, from: index, with: text) else { return false }
        Clipboard.clearPasted(words: parts)
        return true
    }
}

extension View {
    /// A word's box in `NumberedWordGrid` when it is typed into: plain,
    /// 15 pt, never autocorrected.
    func wordBox() -> some View {
        textFieldStyle(.plain)
            .font(Theme.font(15))
            .autocorrectionDisabled()
    }
}

/// The boxes of a `WordCheck`, each numbered with its word's place. Return
/// moves to the next box, and from the last submits.
struct WordCheckGrid: View {
    @Binding var check: WordCheck
    let submit: () -> Void
    @FocusState private var focus: Int?

    var body: some View {
        NumberedWordGrid(places: check.positions, focused: focus) { index in
            TextField("", text: $check.answers[index])
                .focused($focus, equals: index)
                .wordBox()
                .onSubmit { if index + 1 < check.positions.count { focus = index + 1 } else { submit() } }
        }
        .task(id: check.positions) {
            // Focus asked for during the screen change is ignored; ask once it has settled.
            try? await Task.sleep(for: .milliseconds(150))
            focus = 0
        }
    }
}

/// Six boxes over a hidden secure field, so the digits are never shown.
struct PinField: View {
    @Binding var pin: String
    let complete: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ZStack {
            SecureField("", text: $pin)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .focused($focused)
                .opacity(0.01)
                .accessibilityLabel("PIN")
            HStack(spacing: Theme.Space.sm) {
                ForEach(0..<PIN.length, id: \.self) { index in
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
        .onChange(of: isEnabled) { _, enabled in
            // Disabling drops focus (a PIN being checked); take it back once
            // enabled again so a retype after a wrong PIN needs no click.
            guard enabled else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(50))
                focused = true
            }
        }
        .onChange(of: pin) { _, value in
            let digits = PIN.digits(value)
            if digits != value { pin = digits }
            if digits.count == PIN.length { complete() }
        }
    }
}
