import PeelCore
import PeelUI
import SwiftUI

/// You (docs/design/iphone.md, screen 7): your photo, name and balance; the
/// agent; the account's words, PIN, Face ID, boost amount and server; then
/// Forget, the only red. Every change is an `AppModel` operation, as on the
/// Mac's `AccountView`.
struct YouTab: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneRouter.self) private var router
    @State private var editingName = false
    /// What this phone unlocks with, if anything: a system query, made once.
    @State private var biometryName: String?

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.you) {
            List {
                Section { Identity { editingName = true } }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                Section {
                    AgentRow()
                } header: {
                    PhoneSectionHeader("Agent")
                }
                .phoneRows(.grouped)
                Section {
                    NavigationLink(value: YouRoute.words) {
                        LabeledContent("Twelve words", value: model.wordsConfirmed ? "" : "Not checked yet")
                    }
                    if model.profile?.requiresPIN == true {
                        NavigationLink("Change PIN", value: YouRoute.changePIN)
                        if let biometryName { BiometricsRow(name: biometryName) }
                        PINTimeoutRow()
                    }
                    NavigationLink(value: YouRoute.boostAmount) {
                        LabeledContent("Boost amount", value: Sats.format(msat: model.boostAmountMsat))
                    }
                    PaymentConfirmationRow()
                    LabeledContent("Server") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(model.myServer ?? "None")
                            Text(model.connection.label)
                                .phoneFont(.secondary)
                                .foregroundStyle(Theme.quietText(on: .raised))
                        }
                    }
                    .accessibilityElement(children: .combine)
                } header: {
                    PhoneSectionHeader("Account")
                }
                .phoneRows(.grouped)
                .environment(\.surface, .raised)
                Section {
                    ForgetAccount(
                        trigger: "Forget this account",
                        explanation: "Removes the account and its messages from this iPhone. You need your twelve words to sign back in.",
                        destructiveTrigger: true
                    )
                }
                .phoneRows(.grouped)
            }
            .phoneList(.grouped)
            .phoneFont(.row)
            .task { biometryName = model.biometryName }
            .navigationTitle("You")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $editingName) { NameEditor() }
            .navigationDestination(for: YouRoute.self) { route in
                switch route {
                case .words: WordsScreen()
                case .changePIN: ChangePIN()
                case .boostAmount: BoostAmountScreen()
                case .agent, .server: EmptyView()
                }
            }
        }
    }
}

/// Your photo at 64 pt, centred, your name (tap to change it), and the
/// balance under it.
private struct Identity: View {
    @Environment(AppModel.self) private var model
    let editName: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            Avatar(name: model.me.avatarName, url: model.myPhotoURL, size: 64, hue: model.myHue)
                .accessibilityHidden(true)
            Button(action: editName) {
                HStack(spacing: 6) {
                    Text(model.me.name)
                        .phoneFont(.title)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Image(systemName: "pencil")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.tertiaryText)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: Theme.touchTarget)
                .foregroundStyle(Theme.text)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Your name, \(model.me.name)")
            .accessibilityHint("Changes your name")
            Text(model.balanceText ?? "–")
                .phoneFont(PhoneFont(size: 16, style: .body))
                .monospacedDigit()
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityLabel("Balance, \(model.balanceText ?? "not known yet")")
        }
        .frame(maxWidth: .infinity)
    }
}

/// Peel, the agent: its avatar, and where it runs. The brain's status
/// reaches the phone with the remote track; until then, it says where to
/// set it up.
private struct AgentRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            PeelLogo(size: 30)
            Text("Peel")
            AgentTag()
            Spacer(minLength: Theme.Space.sm)
            if let connected = model.agent?.connection {
                Text(connected.model)
                    .foregroundStyle(Theme.quietText(on: .raised))
            } else if model.agentChat != nil {
                // Its account is a contact here (set up on the Mac); follows
                // the conversations, so it changes as the contact arrives.
                Text("Ready")
                    .foregroundStyle(Theme.quietText(on: .raised))
            } else {
                Text("Set up on your Mac")
                    .foregroundStyle(Theme.quietText(on: .raised))
            }
        }
        .frame(minHeight: Theme.touchTarget)
        .accessibilityElement(children: .combine)
    }
}

/// Face ID in place of the PIN (`AppModel.turnOnBiometrics`): on asks for
/// the PIN first, which Face ID will then stand in for; off needs nothing.
private struct BiometricsRow: View {
    @Environment(AppModel.self) private var model
    /// "Face ID", read once by You (a system query).
    let name: String
    @State private var on = false
    @State private var asking = false

    var body: some View {
        Toggle(name, isOn: Binding(get: { on }, set: { wanted in
            if wanted {
                asking = true
            } else {
                Task {
                    try? await model.turnOffBiometrics()
                    on = await model.biometricsOn()
                }
            }
        }))
        .tint(Theme.accent)
        .sheet(isPresented: $asking) {
            Task { on = await model.biometricsOn() }
        } content: {
            TurnOnBiometrics(name: name)
        }
        .task { on = await model.biometricsOn() }
    }
}

private struct TurnOnBiometrics: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let name: String
    @State private var pin = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            PinPrompt(title: "Enter your PIN", detail: problem ?? "\(name) will unlock Peel and show your words in its place.",
                      pin: $pin, working: working) {
                Task { await turnOn() }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func turnOn() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            try await model.turnOnBiometrics(pin: pin)
            dismiss()
        } catch {
            problem = PIN.problem(error)
            pin = ""
        }
    }
}

/// When the PIN is asked for again (the Mac's PIN timeout): only when Peel
/// opens, or after Peel has been away that long.
private struct PINTimeoutRow: View {
    @Environment(AppModel.self) private var model
    @State private var problem: String?

    private static let choices = [0, 1, 4, 12, 24]

    var body: some View {
        let current = model.pinTimeoutHours
        Picker("Ask for the PIN", selection: Binding(get: { current }, set: { hours in
            Task {
                do { try await model.setPINTimeout(hours: hours) } catch { problem = PeelError.problem(error) }
            }
        })) {
            ForEach(presets(Self.choices, including: current), id: \.self) { hours in
                Text(Self.label(hours)).tag(hours)
            }
        }
        .pickerStyle(.menu)
        .tint(Theme.quietText(on: .raised))
        if let problem { ProblemText(problem) }
    }

    private static func label(_ hours: Int) -> String {
        switch hours {
        case 0: "When Peel opens"
        case 1: "After an hour away"
        case 24: "After a day away"
        default: "After \(hours) hours away"
        }
    }
}

/// The amount over which a payment or boost takes a second tap.
private struct PaymentConfirmationRow: View {
    @Environment(AppModel.self) private var model
    @State private var problem: String?

    private static let choices: [UInt64] = [0, 100, 1_000, 10_000].map { $0 * Sats.msatPerSat }

    var body: some View {
        let current = model.paymentConfirmationMsat
        Picker("Confirm payments", selection: Binding(get: { current }, set: { msat in
            Task {
                do { try await model.setPaymentConfirmation(msat: msat) } catch { problem = PeelError.problem(error) }
            }
        })) {
            ForEach(presets(Self.choices, including: current), id: \.self) { msat in
                Text(msat == 0 ? "Always" : "Over \(Sats.format(msat: msat))").tag(msat)
            }
        }
        .pickerStyle(.menu)
        .tint(Theme.quietText(on: .raised))
        if let problem { ProblemText(problem) }
    }
}

/// What the one-tap Boost tips: presets, or another amount. A preset tapped
/// is its own confirmation (it names the amount); a typed amount over the
/// confirmation threshold takes the touch-safe second tap, as a payment does.
private struct BoostAmountScreen: View {
    @Environment(AppModel.self) private var model
    @State private var custom = ""
    @State private var attempt = PaymentAttempt()
    @FocusState private var customFocused: Bool

    private static let choices: [UInt64] = [10, 50, 100, 500, 1_000].map { $0 * Sats.msatPerSat }

    var body: some View {
        let current = model.boostAmountMsat
        List {
            Section {
                ForEach(Self.choices, id: \.self) { msat in
                    Button {
                        attempt.armed = nil
                        Task { _ = await attempt.run { _ in await model.setBoostAmount(msat: msat, confirmedMsat: msat) } }
                    } label: {
                        HStack {
                            Text(Sats.format(msat: msat)).monospacedDigit().foregroundStyle(Theme.text)
                            Spacer()
                            if msat == current {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                        .frame(minHeight: Theme.touchTarget)
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(msat == current ? .isSelected : [])
                }
            } footer: {
                Text("Boost tips a message this much in one tap.")
            }
            .phoneRows(.grouped)
            Section {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    SatsInput(label: "Another amount", text: $custom, focused: $customFocused)
                    TouchPayButton(verb: "Save", totalMsat: Sats.msat(custom), attempt: attempt, send: { confirmed in
                        guard let typed = Sats.msat(custom) else { return .refused("Enter an amount.") }
                        return await model.setBoostAmount(msat: typed, confirmedMsat: confirmed)
                    }, sent: {
                        custom = ""
                        customFocused = false
                    })
                }
                .padding(.vertical, Theme.Space.sm)
            } header: {
                PhoneSectionHeader("Another amount")
            }
            .phoneRows(.grouped)
        }
        .phoneList(.grouped)
        .navigationTitle("Boost amount")
        .navigationBarTitleDisplayMode(.inline)
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

/// Old PIN, new PIN, the new one again, on the keypad; then the words are
/// sealed again (and Face ID, if on, keeps the new PIN).
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
        Group {
            switch step {
            case .old:
                PinPrompt(title: "Enter your current PIN", detail: note, pin: $old) { step = .new }
            case .new:
                PinPrompt(title: "Choose a new PIN", detail: note, pin: $new) {
                    note = nil
                    step = .confirm
                }
            case .confirm:
                PinPrompt(title: "Enter the new PIN again", detail: note, pin: $confirmation, working: working) {
                    Task { await submit() }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
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

/// The twelve words after Face ID or the PIN, hidden again after half a
/// minute or when Peel leaves the screen (covered in the app switcher's
/// snapshot); or, while they are not checked, three of them typed back
/// from paper.
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
    /// Face ID's sheet is up: Peel is inactive behind it, which is not leaving.
    @State private var askingFace = false
    /// Peel went to the background while Face ID was asked: the words that
    /// come back are not shown.
    @State private var leftWhileAsking = false
    /// Bumped by `hide`, so a PIN check still running when the words are
    /// hidden does not show them after all.
    @State private var generation = 0

    var body: some View {
        Group {
            if asking {
                PinPrompt(title: "Enter your PIN", detail: problem ?? "To show your twelve words.", pin: $pin, working: working) {
                    Task { await reveal() }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { hide() } }
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
                        Button { Task { await start(checking: true) } } label: { ActionLabel("Check words") }.primaryAction()
                    }
                    Button { Task { await start(checking: false) } } label: { ActionLabel("Show words", working: askingFace) }
                        .secondaryAction()
                        .disabled(askingFace)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { hide() }
        .onChange(of: scenePhase) { _, phase in
            if askingFace {
                if phase == .background { leftWhileAsking = true }
            } else if phase != .active {
                hide()
            }
        }
    }

    private func start(checking: Bool) async {
        self.checking = checking
        check = WordCheck()
        problem = nil
        guard model.profile?.requiresPIN == true else { return await reveal() }
        if model.biometryName != nil, await model.biometricsOn() {
            askingFace = true
            leftWhileAsking = false
            defer { askingFace = false }
            let started = generation
            do {
                if let revealed = try await model.revealWordsWithBiometrics() {
                    // Not if Peel left the screen while the PIN was checked.
                    guard generation == started, !leftWhileAsking else { return hide() }
                    return show(revealed)
                }
            } catch {
                problem = PIN.problem(error)
            }
        }
        pin = ""
        asking = true
    }

    private func reveal() async {
        guard !working else { return }
        working = true
        defer { working = false }
        let started = generation
        do {
            let revealed = try await model.revealWords(pin: pin)
            guard generation == started else { return }
            show(revealed)
        } catch {
            guard generation == started else { return }
            problem = PIN.problem(error)
        }
        pin = ""
    }

    private func show(_ revealed: [String]) {
        words = revealed
        asking = false
        visible = false
        problem = nil
        hideAt = .now.addingTimeInterval(Self.shownFor)
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
