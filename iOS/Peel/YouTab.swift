import PeelCore
import PeelUI
import SwiftUI

/// You: your name and balance, the server, and the PIN and twelve words that
/// guard the account on this iPhone (the Mac's `AccountView`, in part).
/// Every change is an `AppModel` operation. F2c gives it the design's
/// groups (docs/design/iphone.md, screen 7).
struct YouTab: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.you) {
            List {
                Section {
                    HStack(spacing: 14) {
                        Avatar(name: model.me.avatarName, url: model.myPhotoURL, size: 64, hue: model.myHue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.me.name)
                                .font(Theme.font(22, .bold))
                                .lineLimit(1)
                            Text(model.balanceText ?? "–")
                                .font(Theme.font(16))
                                .monospacedDigit()
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                }
                .phoneRows(.grouped)
                Section("Account") {
                    NavigationLink {
                        NameEditor()
                    } label: {
                        LabeledContent("Name", value: model.myAlias ?? "")
                    }
                    LabeledContent("Balance") {
                        Text(model.balanceText ?? "–").monospacedDigit()
                    }
                    LabeledContent("Server") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(model.myServer ?? "None")
                            Text(model.connection.label)
                                .font(Theme.font(13))
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
                .phoneRows(.grouped)
                Section("Security") {
                    if model.profile?.requiresPIN == true {
                        NavigationLink("Change PIN") { ChangePIN() }
                    }
                    NavigationLink {
                        WordsScreen()
                    } label: {
                        LabeledContent("Twelve words", value: model.wordsConfirmed ? "Checked" : "Not checked yet")
                    }
                }
                .phoneRows(.grouped)
                Section {
                    ForgetAccount(
                        trigger: "Forget this account on this iPhone",
                        explanation: "Removes the account and its messages from this iPhone. You need your twelve words to sign back in."
                    )
                    .padding(.vertical, 4)
                }
                .phoneRows(.grouped)
            }
            .phoneList(.grouped)
            .navigationTitle("You")
        }
    }
}

/// The name others see on the messages sent from now on.
private struct NameEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var working = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        StepPage(title: "Your name", problem: problem) {
            TextField("Name", text: $draft)
                .font(Theme.font(17))
                .textContentType(.nickname)
                .submitLabel(.done)
                .focused($focused)
                .onSubmit { Task { await save() } }
                .padding(.horizontal, Theme.Space.md)
                .frame(height: 50)
                .fieldBox(focused: focused)
        } actions: {
            Button { Task { await save() } } label: { ActionLabel("Save", working: working) }
                .primaryAction()
                .disabled(draft.trimmed.isEmpty || draft.trimmed == model.myAlias || working)
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            draft = model.myAlias ?? ""
            focused = true
        }
    }

    private func save() async {
        guard !draft.trimmed.isEmpty, !working else { return }
        working = true
        defer { working = false }
        do {
            try await model.setName(draft.trimmed)
            dismiss()
        } catch {
            problem = PeelError.problem(error, couldNot: "save your name")
        }
    }
}

/// Old PIN, new PIN, the new one again; then the words are sealed again.
private struct ChangePIN: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Step { case old, new, confirm }
    @State private var step = Step.old
    @State private var old = ""
    @State private var new = ""
    @State private var confirmation = ""
    @State private var working = false
    @State private var note: String?

    var body: some View {
        StepPage(title: title, problem: note) {
            Group {
                switch step {
                case .old: PinBoxes(pin: $old) { step = .new }
                case .new: PinBoxes(pin: $new) { step = .confirm }
                case .confirm: PinBoxes(pin: $confirmation) { Task { await submit() } }
                }
            }
            .id(step)
            .disabled(working)
            ProgressView().opacity(working ? 1 : 0).frame(maxWidth: .infinity)
        } actions: {
            EmptyView()
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var title: String {
        switch step {
        case .old: "Enter your current PIN"
        case .new: "Choose a new PIN"
        case .confirm: "Enter the new PIN again"
        }
    }

    private func reset(to step: Step, note: String?) {
        if step == .old { old = "" }
        new = ""
        confirmation = ""
        self.note = note
        self.step = step
    }

    private func submit() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            try await model.changePIN(from: old, to: new, confirmation: confirmation)
            dismiss()
        } catch let error as SecretStoreFailure where error == .wrongPIN {
            reset(to: .old, note: PIN.problem(error))
        } catch {
            reset(to: .new, note: PeelError.problem(error, couldNot: "change the PIN") + " Choose the new PIN again.")
        }
    }
}

/// The twelve words after the PIN, hidden again after half a minute or when
/// Peel leaves the screen; or, while they are not checked, three of them
/// typed back from paper.
private struct WordsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    private static let shownFor: TimeInterval = 30

    @State private var checking = false
    @State private var asking = false
    @State private var pin = ""
    @State private var words: [String] = []
    @State private var check = WordCheck()
    @State private var visible = false
    @State private var hideAt = Date.distantPast
    @State private var working = false
    @State private var problem: String?
    /// Bumped by `hide`, so a PIN check still running when the words are
    /// hidden does not show them after all.
    @State private var generation = 0

    var body: some View {
        Group {
            if asking {
                StepPage(title: "Enter your PIN", problem: problem) {
                    PinBoxes(pin: $pin) { Task { await reveal() } }
                        .disabled(working)
                } actions: {
                    Button { hide() } label: { ActionLabel("Cancel") }.secondaryAction()
                }
            } else if !words.isEmpty, checking {
                StepPage(title: "Check what you wrote", detail: "Type these three words from your paper.", problem: problem) {
                    WordCheckBoxes(check: $check) { Task { await confirm() } }
                } actions: {
                    Button { Task { await confirm() } } label: { ActionLabel("Check", working: working) }
                        .primaryAction()
                        .disabled(!check.isFilled || working)
                }
            } else if !words.isEmpty {
                StepPage(title: "Your twelve words", detail: "Anyone with these words controls your account. Keep them on paper.") {
                    NumberedWords(places: Array(words.indices)) { index in
                        Text(visible ? words[index] : "••••••")
                            .font(Theme.font(16))
                            .foregroundStyle(visible ? Theme.text : Theme.secondaryText)
                        Spacer(minLength: 0)
                    }
                    .privacySensitive()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Hides in \(max(0, Int(hideAt.timeIntervalSince(context.date).rounded(.up)))) s")
                            .font(Theme.font(14))
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondaryText)
                    }
                } actions: {
                    Button { visible.toggle() } label: { ActionLabel(visible ? "Mask" : "Reveal") }.primaryAction()
                    Button { hide() } label: { ActionLabel("Hide") }.secondaryAction()
                }
                .task(id: hideAt) {
                    try? await Task.sleep(for: .seconds(Self.shownFor))
                    if !Task.isCancelled { hide() }
                }
            } else {
                StepPage(title: "Twelve words",
                         detail: model.wordsConfirmed ? "Checked against your paper." : "Not checked against your paper yet.",
                         problem: problem) {
                    EmptyView()
                } actions: {
                    if !model.wordsConfirmed {
                        Button { start(checking: true) } label: { ActionLabel("Check words") }.primaryAction()
                    }
                    Button { start(checking: false) } label: { ActionLabel("Show words") }
                        .secondaryAction()
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { hide() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { hide() } }
    }

    private func start(checking: Bool) {
        self.checking = checking
        check = WordCheck()
        problem = nil
        if model.profile?.requiresPIN == true {
            pin = ""
            asking = true
        } else {
            Task { await reveal() }
        }
    }

    private func reveal() async {
        guard !working else { return }
        working = true
        defer { working = false }
        let started = generation
        do {
            let revealed = try await model.revealWords(pin: pin)
            guard generation == started else { return }
            words = revealed
            asking = false
            visible = false
            problem = nil
            hideAt = .now.addingTimeInterval(Self.shownFor)
        } catch {
            guard generation == started else { return }
            problem = PIN.problem(error)
        }
        pin = ""
    }

    private func confirm() async {
        guard !working, check.isFilled else { return }
        working = true
        defer { working = false }
        let started = generation
        do {
            try await model.confirmWords(check.byPosition, of: words)
            hide()
        } catch {
            guard generation == started else { return }
            problem = PeelError.problem(error)
        }
    }

    private func hide() {
        generation += 1
        problem = nil
        words = []
        checking = false
        check = WordCheck()
        pin = ""
        asking = false
        visible = false
    }
}
