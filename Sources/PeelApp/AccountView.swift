import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import PeelCore

/// The account screen: who others see, how to be added, the words and PIN
/// that guard the account on this Mac, and leaving it. Opened from the foot
/// of the sidebar or with ⌘,. Every change is an `AppModel` operation.
struct AccountView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: "Account")
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    IdentitySection()
                    ContactInfoSection()
                    SettingsGroup("Account") {
                        NameRow()
                        GroupDivider()
                        SettingsRow("Balance") {
                            Text(model.balanceMsat.map { Formatting.sats(msat: $0) } ?? "Known once connected")
                                .monospacedDigit()
                                .foregroundStyle(model.balanceMsat == nil ? Theme.secondaryText : Theme.text)
                        }
                        GroupDivider()
                        SettingsRow("Confirm payments") {
                            PaymentConfirmationRow()
                        }
                        GroupDivider()
                        SettingsRow("Boost amount") {
                            BoostAmountRow()
                        }
                        GroupDivider()
                        SettingsRow("Server") {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.myServer ?? "None")
                                    .textSelection(.enabled)
                                Text(model.connection.label)
                                    .font(Theme.font(12))
                                    .foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                    SettingsGroup("Security") {
                        if model.profile?.requiresPIN == true {
                            ChangePINRow()
                            GroupDivider()
                            PINTimeoutRow()
                            GroupDivider()
                        }
                        WordsRow()
                    }
                    SettingsGroup("Notifications") {
                        NotificationsRow()
                        GroupDivider()
                        NotificationTextRow()
                    }
                    ForgetAccountControl(
                        trigger: "Forget this account on this Mac",
                        explanation: "This deletes from this Mac your twelve words and every message, contact and tribe stored here. The account itself is not closed: to use it again, here or on any device, you need your twelve words. Make sure you have them written down.",
                        alignment: .leading,
                        triggerColor: Theme.destructive
                    )
                    .padding(.horizontal, 4)
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 32)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
        }
        .font(Theme.font(14))
    }
}

// MARK: - Identity

/// Photo, name and key, with the photo editor below when open.
private struct IdentitySection: View {
    @Environment(AppModel.self) private var model
    @State private var editing = false
    @State private var link = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 20) {
                Avatar(name: model.myAlias ?? "?", url: model.myPhotoURL, size: 88)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.myAlias ?? "You")
                        .font(Theme.font(24, .bold))
                        .lineLimit(1)
                    if let key = model.myPubkey {
                        Text("\(key.prefix(6))…\(key.suffix(4))")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                            .help(key)
                    }
                }
                Spacer(minLength: 12)
                if !editing {
                    Button(model.myPhotoURL == nil ? "Add photo" : "Change photo") {
                        link = model.myPhotoURL ?? ""
                        problem = nil
                        editing = true
                    }
                    .buttonStyle(GhostButtonStyle())
                }
            }
            if editing {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button("Choose a picture…") { Task { await upload() } }
                            .buttonStyle(GhostButtonStyle())
                        Text("or paste a link")
                            .font(Theme.font(12))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    TextField("Link to an image (https)", text: $link)
                        .onboardingField()
                        .onSubmit { if !link.trimmed.isEmpty { Task { await save(link) } } }
                    Text("Shown beside the messages you send from now on.")
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.secondaryText)
                    FormFooter(problem: problem, working: working) {
                        if model.myPhotoURL != nil {
                            Button("Remove photo") { Task { await save("") } }
                                .buttonStyle(GhostButtonStyle())
                        }
                        Button("Cancel") { editing = false }
                            .buttonStyle(GhostButtonStyle())
                        Button("Save") { Task { await save(link) } }
                            .buttonStyle(GhostButtonStyle(prominent: true))
                            .keyboardShortcut(.defaultAction)
                            .disabled(link.trimmed.isEmpty)
                    }
                    .disabled(working)
                }
                .padding(16)
                .panelBoxed()
            }
        }
    }

    /// A picture from this Mac, uploaded to the memes server as the Mac app does.
    private func upload() async {
        guard !working, let file = model.choosePicture() else { return }
        working = true
        defer { working = false }
        do {
            try await model.uploadPhoto(file)
            editing = false
        } catch {
            problem = "Could not upload the picture: \(PeelError.readable(error))"
        }
    }

    private func save(_ url: String) async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            try await model.setPhotoURL(url)
            editing = false
        } catch {
            problem = PeelError.readable(error)
        }
    }
}

/// The QR code and contact info someone needs to add this account.
private struct ContactInfoSection: View {
    @Environment(AppModel.self) private var model
    @State private var code: CGImage?

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.white)
                if let code {
                    Image(decorative: code, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .padding(8)
                }
            }
            .frame(width: 132, height: 132)
            .opacity(model.myContactInfo == nil ? 0.3 : 1)
            .accessibilityLabel("QR code of your contact info")
            VStack(alignment: .leading, spacing: 8) {
                Text("Your contact info")
                    .font(Theme.font(15, .bold))
                Text(model.myContactInfo == nil
                     ? "Available once the server has registered this account."
                     : "Someone scans this code or pastes your contact info to add you. It holds your public key and how to reach you, nothing secret.")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let info = model.myContactInfo {
                    CopyButton("Copy contact info", text: info)
                        .buttonStyle(GhostButtonStyle())
                        .id(info)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .panelBoxed()
        .task(id: model.myContactInfo) {
            code = model.myContactInfo.flatMap(QRCode.image)
        }
    }
}

enum QRCode {
    private static let context = CIContext()

    /// One module per pixel; draw it with `.interpolation(.none)`.
    static func image(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: output.extent)
    }
}

// MARK: - Rows

private struct NameRow: View {
    @Environment(AppModel.self) private var model
    @State private var editing = false
    @State private var draft = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        if editing {
            VStack(alignment: .leading, spacing: 10) {
                SettingsRow("Name") {
                    TextField("Name", text: $draft)
                        .onboardingField()
                        .onSubmit { Task { await save() } }
                }
                Text("Contacts and tribes see it on the messages you send from now on. Messages already sent keep the old name.")
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, settingsValueInset)
                    .padding(.trailing, 16)
                FormFooter(problem: problem, working: working) {
                    Button("Cancel") { editing = false }
                        .buttonStyle(GhostButtonStyle())
                    Button("Save") { Task { await save() } }
                        .buttonStyle(GhostButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft.trimmed.isEmpty || draft.trimmed == model.myAlias)
                }
                .disabled(working)
                .padding([.horizontal, .bottom], 16)
            }
        } else {
            SettingsRow("Name") {
                Text(model.myAlias ?? "")
            } trailing: {
                Button("Edit") {
                    draft = model.myAlias ?? ""
                    problem = nil
                    editing = true
                }
                .buttonStyle(GhostButtonStyle())
            }
        }
    }

    private func save() async {
        guard !draft.trimmed.isEmpty, !working else { return }
        working = true
        defer { working = false }
        do {
            try await model.setName(draft)
            editing = false
        } catch {
            problem = PeelError.readable(error)
        }
    }
}

/// Old PIN, new PIN, the new one again; then the words are sealed again.
private struct ChangePINRow: View {
    @Environment(AppModel.self) private var model

    private enum Step { case closed, old, new, confirm }
    @State private var step = Step.closed
    @State private var old = ""
    @State private var new = ""
    @State private var confirmation = ""
    @State private var working = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow("PIN") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Six digits")
                    if let note, step == .closed {
                        Text(note)
                            .font(Theme.font(12))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            } trailing: {
                if step == .closed {
                    Button("Change") { reset(to: .old) }
                        .buttonStyle(GhostButtonStyle())
                } else {
                    Button("Cancel") { reset(to: .closed) }
                        .buttonStyle(GhostButtonStyle())
                        .disabled(working)
                }
            }
            if step != .closed {
                VStack(alignment: .leading, spacing: 12) {
                    Text(prompt)
                        .font(Theme.font(13))
                        .foregroundStyle(note == nil ? Theme.secondaryText : Theme.text)
                    Group {
                        switch step {
                        case .old: PinField(pin: $old) { step = .new }
                        case .new: PinField(pin: $new) { step = .confirm }
                        default: PinField(pin: $confirmation) { Task { await submit() } }
                        }
                    }
                    .id(step)
                    .frame(maxWidth: 360)
                    .disabled(working)
                    ProgressView().controlSize(.small).opacity(working ? 1 : 0)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }

    private var prompt: String {
        if let note { return note }
        return switch step {
        case .old: "Enter your current PIN."
        case .new: "Choose a new six-digit PIN."
        default: "Enter the new PIN again."
        }
    }

    /// Clears the digits typed so far and moves to `step`.
    private func reset(to step: Step, note: String? = nil) {
        if step != .new { old = "" }
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
            reset(to: .closed, note: "Changed. Use the new PIN from now on.")
        } catch SecretStoreFailure.wrongPIN {
            reset(to: .old, note: "That was not your current PIN. Enter it again.")
        } catch {
            reset(to: .new, note: "Could not change the PIN: \(PeelError.readable(error)). Choose the new PIN again.")
        }
    }
}

private struct PINTimeoutRow: View {
    @Environment(AppModel.self) private var model
    @State private var problem: String?

    private static let choices = [0, 1, 4, 12, 24]

    var body: some View {
        SettingsRow("Ask for the PIN") {
            VStack(alignment: .leading, spacing: 2) {
                PeelDropdown(
                    selection: model.pinTimeoutHours,
                    options: (Self.choices + (Self.choices.contains(model.pinTimeoutHours) ? [] : [model.pinTimeoutHours]))
                        .map { ($0, Self.label($0)) }
                ) { hours in
                    Task {
                        do {
                            try await model.setPINTimeout(hours: hours)
                            problem = nil
                        } catch {
                            problem = PeelError.readable(error)
                        }
                    }
                }
                .fixedSize()
                Text(problem ?? "When Peel comes to the front after this long, it asks again.")
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private static func label(_ hours: Int) -> String {
        switch hours {
        case 0: "Only when Peel opens"
        case 1: "After an hour"
        case 24: "After a day"
        default: "After \(hours) hours"
        }
    }
}

/// The twelve words, after the PIN: hidden behind dots until asked, gone
/// again after a short while, when Peel leaves the front, or when the screen
/// closes. Copying warns first and the clipboard is cleared after a minute.
private struct WordsRow: View {
    @Environment(AppModel.self) private var model

    private static let shownFor: TimeInterval = 30

    @State private var askingPIN = false
    @State private var pin = ""
    @State private var working = false
    @State private var problem: String?
    @State private var words: [String] = []
    @State private var hideAt = Date.distantPast
    @State private var visible = false
    @State private var confirmingCopy = false
    /// When the words were last copied: the Copy button shows its check.
    @State private var copiedAt: Date?
    /// Bumped by `hide`, so a PIN check still running when the words are
    /// hidden (Cancel, Peel leaving the front) does not show them after all.
    @State private var generation = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow("Twelve words") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.usesFileSecrets ? "In a plain file (development profile)" : "In the Keychain on this Mac")
                    Text(model.profile?.requiresPIN == true ? "Asks for your PIN first" : "No PIN on a development profile")
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.secondaryText)
                }
            } trailing: {
                if words.isEmpty, !askingPIN {
                    Button("Show words") { start() }
                        .buttonStyle(GhostButtonStyle())
                } else {
                    Button(words.isEmpty ? "Cancel" : "Hide") { hide() }
                        .buttonStyle(GhostButtonStyle())
                }
            }
            if askingPIN {
                VStack(alignment: .leading, spacing: 12) {
                    Text(problem ?? "Enter your PIN to show your twelve words.")
                        .font(Theme.font(13))
                        .foregroundStyle(problem == nil ? Theme.secondaryText : Theme.text)
                    PinField(pin: $pin) { Task { await reveal() } }
                        .frame(maxWidth: 360)
                        .disabled(working)
                    ProgressView().controlSize(.small).opacity(working ? 1 : 0)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            } else if !words.isEmpty {
                shown
            } else if let problem {
                ProblemText(problem)
                    .padding([.horizontal, .bottom], 16)
            }
        }
        .onDisappear { hide() }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in hide() }
        #endif
    }

    private var shown: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Anyone who has these words controls your account and its sats. Write them on paper; never type them into a website or a chat.")
                .font(Theme.font(13))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            NumberedWordGrid(count: words.count) { index in
                Text(visible ? words[index] : "••••••")
                    .font(Theme.font(15))
                    .foregroundStyle(visible ? Theme.text : Theme.secondaryText)
                Spacer(minLength: 0)
            }
            .privacySensitive()
            HStack(spacing: 8) {
                Button(visible ? "Mask" : "Reveal") { visible.toggle() }
                    .buttonStyle(GhostButtonStyle())
                if confirmingCopy {
                    Text("Other apps can read the clipboard. Peel clears it after a minute.")
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Cancel") { confirmingCopy = false }
                        .buttonStyle(GhostButtonStyle())
                    Button("Copy words") {
                        Clipboard.copySecret(words.joined(separator: " "), clearAfter: .seconds(60))
                        confirmingCopy = false
                        copiedAt = .now
                        CopyFeedback.announce()
                    }
                    .buttonStyle(GhostButtonStyle(prominent: true))
                } else {
                    Button { confirmingCopy = true } label: { CopyLabel("Copy", copiedAt: copiedAt) }
                        .buttonStyle(GhostButtonStyle())
                    if copiedAt != nil {
                        Text("Cleared from the clipboard in a minute")
                            .font(Theme.font(12))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                Spacer(minLength: 8)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Hides in \(max(0, Int(hideAt.timeIntervalSince(context.date).rounded(.up)))) s")
                        .font(Theme.font(12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .padding([.horizontal, .bottom], 16)
        .task(id: hideAt) {
            try? await Task.sleep(for: .seconds(Self.shownFor))
            if !Task.isCancelled { hide() }
        }
    }

    private func start() {
        problem = nil
        if model.profile?.requiresPIN == true {
            pin = ""
            askingPIN = true
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
            askingPIN = false
            visible = false
            hideAt = .now.addingTimeInterval(Self.shownFor)
        } catch {
            guard generation == started else { return }
            problem = PIN.problem(error)
        }
        pin = ""
    }

    private func hide() {
        generation += 1
        problem = nil
        words = []
        pin = ""
        askingPIN = false
        visible = false
        confirmingCopy = false
        copiedAt = nil
    }
}

// MARK: - Notifications

/// Whether macOS lets Peel show notifications, and the way to change it.
private struct NotificationsRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsRow("Notifications") {
            VStack(alignment: .leading, spacing: 2) {
                Text(state)
                Text(note)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondaryText)
            }
        } trailing: {
            switch model.notifier.permission {
            case .notAsked:
                Button("Turn on") { Task { await model.enableNotifications() } }
                    .buttonStyle(GhostButtonStyle(prominent: true))
            case .allowed, .denied:
                Button("System Settings…") { model.openNotificationSettings() }
                    .buttonStyle(GhostButtonStyle())
            case .unavailable:
                EmptyView()
            }
        }
    }

    private var state: String {
        switch model.notifier.permission {
        case .allowed: "On"
        case .notAsked: "Off"
        case .denied: "Turned off in System Settings"
        case .unavailable: "Unavailable"
        }
    }

    private var note: String {
        switch model.notifier.permission {
        case .allowed: "For new messages while you're elsewhere, by each chat's notification level. Sounds and Focus follow System Settings."
        case .notAsked: "Peel asks macOS once; you can change it later in System Settings."
        case .denied: "Allow Peel under Notifications in System Settings to get them."
        case .unavailable: "Only when Peel runs as an app."
        }
    }
}

private struct NotificationTextRow: View {
    @Environment(AppModel.self) private var model
    @State private var problem: String?

    var body: some View {
        SettingsRow("Message text") {
            VStack(alignment: .leading, spacing: 2) {
                PeelDropdown(
                    selection: model.notifier.showsText,
                    options: [(true, "Show message text"), (false, "Say only \"New message\"")]
                ) { shows in
                    Task {
                        do {
                            try await model.setNotificationShowsText(shows)
                            problem = nil
                        } catch {
                            problem = PeelError.readable(error)
                        }
                    }
                }
                .fixedSize()
                Text(problem ?? "What a notification shows of a message. It always names the sender; while Peel is locked it shows neither.")
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

// MARK: - Building blocks

/// A titled box of rows, as on the design board.
private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title.uppercased())
                .tracking(0.5)
                .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .panelBoxed()
        }
    }
}

private struct GroupDivider: View {
    var body: some View { Theme.divider.frame(height: 1) }
}

private let settingsLabelWidth: CGFloat = 150
private let settingsRowPadding: CGFloat = 16
private let settingsRowSpacing: CGFloat = 12
/// Where a row's value column starts, for notes under it.
private let settingsValueInset = settingsRowPadding + settingsLabelWidth + settingsRowSpacing

/// Label column, value, and an optional action on the right.
private struct SettingsRow<Value: View, Trailing: View>: View {
    let label: String
    @ViewBuilder let value: Value
    @ViewBuilder let trailing: Trailing

    init(_ label: String, @ViewBuilder value: () -> Value, @ViewBuilder trailing: () -> Trailing) {
        self.label = label
        self.value = value()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: settingsRowSpacing) {
            Text(label)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: settingsLabelWidth, alignment: .leading)
            value
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, settingsRowPadding)
        .padding(.vertical, 12)
        .frame(minHeight: 52)
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.init(label, value: value, trailing: { EmptyView() })
    }
}

/// The quiet bordered button of the account screen; `prominent` for the one
/// that commits (`fill` in place of the button colour, such as orange for a
/// payment waiting for its second click).
struct GhostButtonStyle: ButtonStyle {
    var prominent = false
    var fill: Color?
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(13, prominent ? .medium : .regular))
            .foregroundStyle(prominent ? Theme.buttonText : Theme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(prominent ? fill ?? Theme.button : configuration.isPressed ? Theme.hover : .clear)
            )
            .overlay {
                if !prominent { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.divider) }
            }
            .opacity(isEnabled ? (configuration.isPressed && prominent ? 0.85 : 1) : 0.45)
            .contentShape(Rectangle())
    }
}
