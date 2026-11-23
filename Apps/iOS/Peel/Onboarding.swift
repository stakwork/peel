import PeelCore
import PeelUI
import SwiftUI

/// New account (invite, name, PIN, the twelve words) or restore (the words,
/// PIN, progress; the name and photo come back from the account's own sent
/// messages, or, when none comes back, a name step after the progress
/// screen), as the Mac's `OnboardingView` asks them, each step
/// pushed so Back is the system's. See docs/design/README.md, "Profile and
/// onboarding".
struct Onboarding: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneRouter.self) private var router

    enum Path { case newAccount, restore }
    enum Step: Hashable { case invite, enterWords, name, pin, confirmPin, showWords, checkWords, restoring, restoreName }

    @State private var path = Path.newAccount
    @State private var steps: [Step] = []
    @State private var invite = ""
    @State private var scanningInvite = false
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
                        .navigationBarBackButtonHidden([.showWords, .restoring, .restoreName].contains(step))
                }
        }
        // A worker's invite that came by a tapped link or the clipboard
        // (`PhoneRouter.take(invite:)`): the invite step filled in, on the new-account path.
        .onAppear { fillInInvite() }
        .onChange(of: router.pendingInvite) { _, _ in fillInInvite() }
        .onChange(of: steps) { old, new in
            problem = problemAfterBack
            problemAfterBack = nil
            // Leaving the flow forgets what was typed; stepping back within it keeps it.
            if new.isEmpty {
                invite = ""
                name = ""
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
                Text("Private messages, payments, and an assistant that works for you.")
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
                Button { start(.newAccount, at: .invite) } label: { ActionLabel(String(localized: "Join with an invite")) }
                    .primaryAction()
                Button { start(.restore, at: .enterWords) } label: { ActionLabel(String(localized: "Restore with recovery words")) }
                    .secondaryAction()
                Text("No invite? Ask a friend who uses Peel.")
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
            StepPage(title: String(localized: "Paste your invite"), detail: String(localized: "The link or code someone sent you."),
                     progress: progress(step), problem: problem) {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                TextField("sphinx.chat/?action=i&d=…", text: $invite, axis: .vertical)
                    .font(Theme.font(16))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(2...5)
                    .padding(Theme.Space.md)
                    .padding(.trailing, 32)
                    .overlay(alignment: .topTrailing) {
                        Button { scanningInvite = true } label: {
                            Image(systemName: "qrcode.viewfinder")
                                .font(Theme.font(20))
                                .padding(Theme.Space.md)
                        }
                        .accessibilityLabel("Scan invite QR code")
                    }
                    .fieldBox(focused: false)
                    .fullScreenCover(isPresented: $scanningInvite) {
                        CodeScanner(
                            title: String(localized: "Scan your invite"), prompt: String(localized: "Point the camera at the invite's QR code."),
                            pasteInstead: String(localized: "paste the invite"), cancel: { scanningInvite = false }
                        ) { code in
                            guard !code.trimmed.isEmpty else { return String(localized: "That code is empty.") }
                            invite = code
                            scanningInvite = false
                            return nil
                        }
                    }
                    // Apple's own paste control: pasting from it asks nothing ("Allow Paste?"), unlike reading the
                    // clipboard unasked. A strut https join link becomes the link the core reads, as the clipboard path does.
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        invite = InviteLink.fromClipboard(text) ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    .buttonBorderShape(.capsule)
                }
            } actions: {
                continueButton(enabled: !invite.trimmed.isEmpty) {
                    // A worker's invite also names the app to open once the account is ready, wherever the invite came from.
                    router.takeInviteApp(from: invite)
                    go(.name)
                }
            }
        case .enterWords:
            StepPage(title: String(localized: "Restore with recovery words"), detail: String(localized: "Type them in order, or paste all twelve."),
                     progress: progress(step), problem: problem) {
                WordEntry(words: $words)
            } actions: {
                continueButton(enabled: words.allSatisfy { !$0.isEmpty }) {
                    // Catch a mistyped word here, not after the PIN.
                    do {
                        _ = try Engine.validate(mnemonic: words.joined(separator: " "))
                        go(.pin)
                    } catch {
                        problem = String(localized: "Those twelve words don't make a valid account. Check each one.")
                    }
                }
            }
        case .name:
            StepPage(title: String(localized: "What should people call you?"), progress: progress(step), problem: problem) {
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
            StepPage(title: String(localized: "Set a PIN"),
                     progress: progress(step), problem: problem) {
                PinBoxes(pin: $pin) { go(.confirmPin) }
            } actions: {
                continueButton(enabled: pin.count == PIN.length) { go(.confirmPin) }
            }
        case .confirmPin:
            StepPage(title: String(localized: "Enter your PIN again"), progress: progress(step), problem: problem) {
                PinBoxes(pin: $confirmation) { Task { await confirmPin() } }
                    .disabled(working)
            } actions: {
                Button { Task { await confirmPin() } } label: {
                    ActionLabel(path == .newAccount ? String(localized: "Create account") : String(localized: "Restore"), working: working)
                }
                .primaryAction()
                .disabled(confirmation.count != PIN.length || working)
            }
        case .showWords:
            StepPage(title: String(localized: "Write down your twelve words"),
                     detail: String(localized: "Anyone with these words controls your account."),
                     progress: progress(step), problem: problem) {
                NumberedWords(places: Array(shownWords.indices)) { index in
                    Text(shownWords[index])
                        .font(Theme.font(16))
                        .privacySensitive()
                    Spacer(minLength: 0)
                }
                if model.myContactInfo == nil {
                    // Signed up, the server's answer not yet in (as on the Mac).
                    ProblemText(String(localized: "Not confirmed yet. If it stays this way, ask for a new invite."))
                }
            } actions: {
                Button { go(.checkWords) } label: { ActionLabel(String(localized: "I've written them down")) }
                    .primaryAction()
            }
        case .checkWords:
            StepPage(title: String(localized: "Check what you wrote"), detail: String(localized: "Type these three words from your paper."),
                     progress: progress(step), problem: problem) {
                WordCheckBoxes(check: $check) { Task { await checkWords() } }
            } actions: {
                Button { Task { await checkWords() } } label: { ActionLabel(String(localized: "Open Peel"), working: working) }
                    .primaryAction()
                    .disabled(!check.isFilled || working)
            }
        case .restoring:
            RestoreProgress(onOpen: openAfterRestore)
        case .restoreName:
            StepPage(title: String(localized: "What should people call you?"),
                     detail: String(localized: "We couldn't find a name in your account's history."), problem: problem) {
                TextField("Name", text: $name)
                    .font(Theme.font(17))
                    .textContentType(.nickname)
                    .submitLabel(.continue)
                    .onSubmit { if !name.trimmed.isEmpty { Task { await finishRestore() } } }
                    .padding(.horizontal, Theme.Space.md)
                    .frame(height: 50)
                    .fieldBox(focused: false)
            } actions: {
                Button { Task { await finishRestore() } } label: { ActionLabel(String(localized: "Continue"), working: working) }
                    .primaryAction()
                    .disabled(name.trimmed.isEmpty || working)
            }
        }
    }

    private func continueButton(enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { ActionLabel(String(localized: "Continue")) }
            .primaryAction()
            .disabled(!enabled)
    }

    // MARK: Actions

    /// The numbered steps of the current path; confirming the PIN counts as
    /// the PIN step, checking the words as the words step.
    private var numbered: [Step] {
        path == .newAccount ? [.invite, .name, .pin, .showWords] : [.enterWords, .pin]
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

    /// The invite waiting for this screen goes into the invite step; the person
    /// still taps Continue, then names themself and sets a PIN, as ever.
    private func fillInInvite() {
        guard let link = router.takePendingInvite() else { return }
        start(.newAccount, at: .invite)
        invite = link
    }

    private func go(_ step: Step) {
        problem = nil
        steps.append(step)
    }

    private func confirmPin() async {
        guard !working, confirmation.count == PIN.length else { return }
        guard confirmation == pin else {
            // Shown once the step change below has cleared both PINs.
            problemAfterBack = String(localized: "The PINs don't match. Set it again.")
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
                try await model.restoreAccount(words: words, pin: pin)
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

    /// "Open Peel" on the progress screen: on, unless the restore settled
    /// with no name to show for it, in which case one is asked for first.
    private func openAfterRestore() {
        if model.myAlias?.nilIfEmpty == nil {
            go(.restoreName)
        } else {
            model.enterApp()
        }
    }

    private func finishRestore() async {
        guard !working, !name.trimmed.isEmpty else { return }
        working = true
        defer { working = false }
        do {
            try await model.setName(name.trimmed)
            model.enterApp()
        } catch {
            problem = PeelError.problem(error, couldNot: String(localized: "save your name"))
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
    /// Enters the app, unless the restore settled with no name, which asks
    /// for one first (`Onboarding.openAfterRestore`).
    let onOpen: () -> Void

    var body: some View {
        let progress = model.restoreProgress
        StepPage(title: String(localized: "Restoring your account"), detail: String(localized: "You can start now while older messages arrive.")) {
            let lines = progress.lines(connection: model.connection)
            VStack(spacing: 0) {
                ForEach(lines.indices, id: \.self) { index in
                    if index > 0 { Divider().overlay(Theme.divider) }
                    RestoreLine(line: lines[index])
                }
            }
            .background(Theme.quote, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
            if let failure = progress.paused {
                ProblemText(failure)
            }
        } actions: {
            Button(action: onOpen) { ActionLabel(String(localized: "Open Peel")) }
                .primaryAction()
        }
    }
}

struct RestoreLine: View {
    let line: AppModel.RestoreProgress.Line

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                switch line.state {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                case .active: ProgressView()
                case .waiting: Image(systemName: "circle").foregroundStyle(Theme.divider)
                }
            }
            .font(.system(size: 20))
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(line.title)
                        .font(Theme.font(16))
                        .foregroundStyle(line.state == .waiting ? Theme.secondaryText : Theme.text)
                    Spacer()
                    Text(line.detail)
                        .font(Theme.font(14))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                }
                if let fraction = line.fraction, line.state == .active {
                    ProgressView(value: fraction)
                }
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, 14)
    }
}
