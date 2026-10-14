import PeelCore
import PeelUI
import SwiftUI

/// New account (invite, name, PIN, the twelve words) or restore (the words,
/// name, PIN, progress), as the Mac's `OnboardingView` asks them, each step
/// pushed so Back is the system's. See docs/design/README.md, "Profile and
/// onboarding".
struct Onboarding: View {
    @Environment(AppModel.self) private var model

    enum Path { case newAccount, restore }
    enum Step: Hashable { case invite, enterWords, name, pin, confirmPin, showWords, checkWords, restoring }

    @State private var path = Path.newAccount
    @State private var steps: [Step] = []
    @State private var invite = ""
    @State private var words = Array(repeating: "", count: 12)
    @State private var name = ""
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var shownWords: [String] = []
    @State private var check = WordCheck()
    @State private var working = false
    @State private var problem: String?
    /// What the next step change shows, rather than clearing `problem`.
    @State private var problemAfterBack: String?

    var body: some View {
        NavigationStack(path: $steps) {
            welcome
                .navigationDestination(for: Step.self) { step in
                    page(step)
                        .navigationBarTitleDisplayMode(.inline)
                        // Once the account exists there is no way back before it.
                        .navigationBarBackButtonHidden([.showWords, .restoring].contains(step))
                }
        }
        .onChange(of: steps) { old, new in
            problem = problemAfterBack
            problemAfterBack = nil
            // Leaving the flow forgets what was typed; stepping back within it keeps it.
            if new.isEmpty {
                invite = ""
                words = Array(repeating: "", count: 12)
            }
            // Back from confirming the PIN sets it again.
            if old.last == .confirmPin, new.last == .pin {
                pin = ""
                confirmation = ""
            }
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 28) {
            Spacer()
            AppIcon(size: 96)
            VStack(spacing: 10) {
                Text("Welcome to Peel")
                    .font(Theme.font(32, .bold))
                Text("Sphinx messages and sats on your iPhone.")
                    .font(Theme.font(17))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            if let notice = model.notice {
                ProblemText(notice)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            VStack(spacing: 12) {
                Button { start(.newAccount, at: .invite) } label: { ActionLabel("I have an invite") }
                    .primaryAction()
                Button { start(.restore, at: .enterWords) } label: { ActionLabel("Restore from twelve words") }
                    .secondaryAction()
                Text("No invite? Ask someone on Sphinx.")
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, Theme.Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private func page(_ step: Step) -> some View {
        switch step {
        case .invite:
            StepPage(title: "Paste your invite", detail: "The link or code someone sent you.",
                     progress: progress(step), problem: problem) {
                TextField("sphinx.chat/?action=i&d=…", text: $invite, axis: .vertical)
                    .font(Theme.font(16))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(2...5)
                    .padding(Theme.Space.md)
                    .fieldBox(focused: false)
            } actions: {
                continueButton(enabled: !invite.trimmed.isEmpty) { go(.name) }
            }
        case .enterWords:
            StepPage(title: "Restore from twelve words", detail: "Type them in order, or paste all twelve.",
                     progress: progress(step), problem: problem) {
                WordEntry(words: $words)
            } actions: {
                continueButton(enabled: words.allSatisfy { !$0.isEmpty }) {
                    // Catch a mistyped word here, not after the name and PIN.
                    do {
                        _ = try Engine.validate(mnemonic: words.joined(separator: " "))
                        go(.name)
                    } catch {
                        problem = "Those twelve words don't make a valid account. Check each one."
                    }
                }
            }
        case .name:
            StepPage(title: "What should people call you?", progress: progress(step), problem: problem) {
                TextField("Name", text: $name)
                    .font(Theme.font(17))
                    .textContentType(.nickname)
                    .submitLabel(.continue)
                    .onSubmit { if !name.trimmed.isEmpty { go(.pin) } }
                    .padding(.horizontal, Theme.Space.md)
                    .frame(height: 50)
                    .fieldBox(focused: false)
            } actions: {
                continueButton(enabled: !name.trimmed.isEmpty) { go(.pin) }
            }
        case .pin:
            StepPage(title: "Set a PIN",
                     progress: progress(step), problem: problem) {
                PinBoxes(pin: $pin) { go(.confirmPin) }
            } actions: {
                continueButton(enabled: pin.count == PIN.length) { go(.confirmPin) }
            }
        case .confirmPin:
            StepPage(title: "Enter your PIN again", progress: progress(step), problem: problem) {
                PinBoxes(pin: $confirmation) { Task { await confirmPin() } }
                    .disabled(working)
            } actions: {
                Button { Task { await confirmPin() } } label: {
                    ActionLabel(path == .newAccount ? "Create account" : "Restore", working: working)
                }
                .primaryAction()
                .disabled(confirmation.count != PIN.length || working)
            }
        case .showWords:
            StepPage(title: "Write down your twelve words",
                     detail: "Anyone with these words controls your account.",
                     progress: progress(step), problem: problem) {
                NumberedWords(places: Array(shownWords.indices)) { index in
                    Text(shownWords[index])
                        .font(Theme.font(16))
                        .privacySensitive()
                    Spacer(minLength: 0)
                }
                if model.myContactInfo == nil {
                    // Signed up, the server's answer not yet in (as on the Mac).
                    ProblemText("Not confirmed yet. If it stays this way, ask for a new invite.")
                }
            } actions: {
                Button { go(.checkWords) } label: { ActionLabel("I've written them down") }
                    .primaryAction()
            }
        case .checkWords:
            StepPage(title: "Check what you wrote", detail: "Type these three words from your paper.",
                     progress: progress(step), problem: problem) {
                WordCheckBoxes(check: $check) { Task { await checkWords() } }
            } actions: {
                Button { Task { await checkWords() } } label: { ActionLabel("Open Peel", working: working) }
                    .primaryAction()
                    .disabled(!check.isFilled || working)
            }
        case .restoring:
            RestoreProgress()
        }
    }

    private func continueButton(enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { ActionLabel("Continue") }
            .primaryAction()
            .disabled(!enabled)
    }

    // MARK: Actions

    /// The numbered steps of the current path; confirming the PIN counts as
    /// the PIN step, checking the words as the words step.
    private var numbered: [Step] {
        path == .newAccount ? [.invite, .name, .pin, .showWords] : [.enterWords, .name, .pin]
    }

    private func progress(_ step: Step) -> (step: Int, of: Int)? {
        let counted = step == .confirmPin ? .pin : step == .checkWords ? .showWords : step
        return numbered.firstIndex(of: counted).map { ($0 + 1, numbered.count) }
    }

    private func start(_ path: Path, at step: Step) {
        self.path = path
        model.notice = nil
        steps = [step]
    }

    private func go(_ step: Step) {
        problem = nil
        steps.append(step)
    }

    private func confirmPin() async {
        guard !working, confirmation.count == PIN.length else { return }
        guard confirmation == pin else {
            // Shown once the step change below has cleared both PINs.
            problemAfterBack = "The PINs don't match. Set it again."
            steps.removeLast()
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
}

/// Contacts, then messages, as the server sends them back (the Mac's
/// `RestoreProgressView`). Peel opens before history finishes.
struct RestoreProgress: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let progress = model.restoreProgress
        StepPage(title: "Restoring your account", detail: "You can start now while older messages arrive.") {
            VStack(spacing: 0) {
                RestoreLine(title: "Account", detail: model.connection.label,
                            state: model.connection == .connected ? .done : .active)
                Divider().overlay(Theme.divider)
                RestoreLine(title: "Contacts", detail: progress.label(progress.contacts, noun: "checked"),
                            state: .from(started: progress.contacts != nil, done: progress.messages != nil || progress.finished))
                Divider().overlay(Theme.divider)
                RestoreLine(title: "Messages", detail: progress.label(progress.messages, noun: "received"),
                            state: .from(started: progress.messages != nil, done: progress.finished),
                            fraction: progress.messages?.fraction)
            }
            .background(Theme.quote, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
            if case .failed(let failure) = progress.outcome {
                ProblemText(failure)
            }
        } actions: {
            Button { model.enterApp() } label: { ActionLabel("Open Peel") }
                .primaryAction()
        }
    }
}

struct RestoreLine: View {
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
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                case .active: ProgressView()
                case .waiting: Image(systemName: "circle").foregroundStyle(Theme.divider)
                }
            }
            .font(.system(size: 20))
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(Theme.font(16))
                        .foregroundStyle(state == .waiting ? Theme.secondaryText : Theme.text)
                    Spacer()
                    Text(detail)
                        .font(Theme.font(14))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                }
                if let fraction, state == .active {
                    ProgressView(value: fraction)
                }
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, 14)
    }
}
