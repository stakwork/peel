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
                // Settings, not a form: rows of what is set on cards
                // (`SettingsSection`); a text field, when one opens, is a
                // `FormItem`.
                VStack(alignment: .leading, spacing: 18) {
                    IdentitySection()
                    ContactInfoSection()
                    SettingsSection("Account") {
                        NameRow()
                        SettingsRow("Balance") {
                            Text(model.balanceText ?? "Known once connected")
                                .monospacedDigit()
                                .foregroundStyle(model.balanceMsat == nil ? Theme.secondaryText : Theme.text)
                        }
                        SettingsRow("Confirm payments") {
                            PaymentConfirmationRow()
                        }
                        SettingsRow("Boost amount") {
                            BoostAmountRow()
                        }
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
                    TimeZoneSection()
                    SettingsSection("Security") {
                        if model.profile?.requiresPIN == true {
                            ChangePINRow()
                            PINTimeoutRow()
                        }
                        WordsRow()
                        WebsiteDataRow()
                    }
                    SettingsSection("Notifications") {
                        NotificationsRow()
                        NotificationTextRow()
                    }
                    ForgetAccountControl(
                        trigger: "Forget this account on this Mac…",
                        explanation: "This deletes from this Mac your twelve words and every message, contact and tribe stored here. The account itself is not closed: to use it again, here or on any device, you need your twelve words. Make sure you have them written down.",
                        section: true
                    )
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 32)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
                // In the scroll view as well: a click there never reaches a gesture outside it.
                .endsEditingOnClick()
            }
        }
        .endsEditingOnClick()
        .font(Theme.font(13))
    }
}

// MARK: - Identity

/// Photo, name and key. A photo is chosen or dropped, uploaded at once,
/// and removed after a second click; its link is never shown.
private struct IdentitySection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PictureField(
            picture: Avatar(name: model.me.avatarName, url: model.myPhotoURL, size: 88, hue: model.myHue),
            upload: { try await model.uploadPhoto($0) },
            remove: model.myPhotoURL == nil ? nil : .confirmed("Remove photo") { try await model.removePhoto() }
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.me.name)
                    .font(Theme.font(24, .bold))
                    .lineLimit(1)
                if let key = model.myPubkey {
                    Text(Formatting.shortKey(key))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                        .help(key)
                }
            }
            .padding(.leading, 8)
            Spacer(minLength: 12)
        }
    }
}

/// The QR code and contact info someone needs to add this account.
private struct ContactInfoSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            QRCodeTile(text: model.myContactInfo, label: "QR code of your contact info")
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
                        .buttonStyle(.peel(.outline))
                        .id(info)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .formCard()
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
            VStack(alignment: .leading, spacing: 14) {
                FormItem(
                    label: "Name",
                    helper: "Contacts and tribes see it on the messages you send from now on. Messages already sent keep the old name."
                ) {
                    FormTextField(label: "Name", text: $draft)
                        .onSubmit { Task { await save() } }
                        .disabled(working)
                }
                .padding([.horizontal, .top], settingsRowPadding)
                FormFooter(problem: problem) {
                    Button("Cancel") { editing = false }
                        .buttonStyle(.peel(.outline))
                        .disabled(working)
                    // On while it saves, keeping its fill under the spinner;
                    // `save` ignores a second click.
                    Button { Task { await save() } } label: { Text("Save").buttonProgress(working) }
                        .buttonStyle(.peel(.primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft.trimmed.isEmpty || draft.trimmed == model.myAlias)
                }
                .padding([.horizontal, .bottom], settingsRowPadding)
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
                .buttonStyle(.peel(.outline))
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
            problem = PeelError.problem(error, couldNot: "save your name")
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
                        .buttonStyle(.peel(.outline))
                } else {
                    Button("Cancel") { reset(to: .closed) }
                        .buttonStyle(.peel(.outline))
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
                .padding(.horizontal, settingsRowPadding)
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
            reset(to: .new, note: PeelError.problem(error, couldNot: "change the PIN") + " Choose the new PIN again.")
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
                    options: presets(Self.choices, including: model.pinTimeoutHours)
                        .map { ($0, Self.label($0)) }
                ) { hours in
                    Task {
                        do {
                            try await model.setPINTimeout(hours: hours)
                            problem = nil
                        } catch {
                            problem = PeelError.problem(error, couldNot: "change the setting")
                        }
                    }
                }
                .fixedSize()
                Text(problem ?? "After this long without use, Peel asks again.")
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
                        .buttonStyle(.peel(.outline))
                } else {
                    Button(words.isEmpty ? "Cancel" : "Hide") { hide() }
                        .buttonStyle(.peel(.outline))
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
                .padding(.horizontal, settingsRowPadding)
                .padding(.bottom, 8)
            } else if !words.isEmpty {
                shown
            } else if let problem {
                ProblemText(problem)
                    .padding([.horizontal, .bottom], settingsRowPadding)
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
                    .buttonStyle(.peel(.outline))
                // Not a loss, so the second click is the commit button, not red.
                InlineConfirm(
                    prompt: "Other apps can read the clipboard. Peel clears it after a minute.", confirm: "Copy words",
                    confirmKind: .primary, confirming: $confirmingCopy
                ) {
                    Clipboard.copySecret(words.joined(separator: " "), clearAfter: .seconds(60))
                    copiedAt = .now
                    CopyFeedback.announce()
                } trigger: {
                    CopyLabel("Copy", copiedAt: copiedAt)
                }
                if !confirmingCopy, copiedAt != nil {
                    Text("Cleared from the clipboard in a minute")
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.secondaryText)
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
        .padding([.horizontal, .bottom], settingsRowPadding)
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

// MARK: - Time zone

/// The zone your offset comes from (this Mac's, or one chosen from a
/// searchable list, `ZonePicker`), and how many chats it goes to.
private struct TimeZoneSection: View {
    @Environment(AppModel.self) private var model
    @State private var chosen: String?
    @State private var picking = false
    @State private var hovering = false
    @State private var problem: String?
    @State private var shared: Int?

    /// What is sent: the chosen zone, else this Mac's.
    private var zone: TimeZone { chosen.flatMap(TimeZoneOffset.zone) ?? .autoupdatingCurrent }

    var body: some View {
        SettingsSection("Time zone") {
            SettingsRow("Time zone") {
                VStack(alignment: .leading, spacing: 4) {
                    Button { picking = true } label: {
                        HStack(spacing: 8) {
                            Text(chosen.map(ZonePicker.label) ?? ZonePicker.automatic)
                                .lineLimit(1)
                            Text(TimeZoneOffset.format(zone))
                                .foregroundStyle(Theme.secondaryText)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        .font(Theme.font(13))
                        .monospacedDigit()
                        .dropdownBoxed(hovering: hovering)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering = $0 }
                    .fixedSize()
                    .peelPopover(isPresented: $picking) {
                        ZonePicker(chosen: chosen, close: { picking = false }) { identifier in
                            picking = false
                            Task { await choose(identifier) }
                        }
                    }
                    note(problem ?? "Used in every chat you share with. Follows this Mac; choose one when you are travelling but want to keep home hours.")
                }
            }
            SettingsRow("Shared in") {
                VStack(alignment: .leading, spacing: 2) {
                    switch shared {
                    case nil: EmptyView()
                    case 0: Text("No chats")
                    case let count?:
                        Text("\(count == 1 ? "1 chat" : "\(count) chats") \(Text("· as \(TimeZoneOffset.format(zone))").foregroundStyle(Theme.secondaryText))")
                            .monospacedDigit()
                    }
                    note("Every direct message and private tribe, unless you turn it off in that chat's details. Never in public tribes. Each message carries the offset of the moment it is sent, so it follows summer time. You see other people's local time either way.")
                }
            }
        }
        .task { chosen = try? await model.engine?.chosenTimeZone() }
        .task(id: model.conversations.count) { await countShared() }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(12))
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func choose(_ identifier: String?) async {
        do {
            try await model.setTimeZone(identifier)
            chosen = identifier
            problem = nil
        } catch {
            problem = PeelError.problem(error, couldNot: "change the time zone")
        }
    }

    /// Every chat whose messages carry the offset now.
    private func countShared() async {
        guard let engine = model.engine else { return }
        var count = 0
        for conversation in model.conversations {
            if (try? await engine.offsetShared(in: conversation.chat)) != nil { count += 1 }
        }
        shared = count
    }
}

/// Automatic, then every zone this Mac knows, filtered as you type a city
/// or an offset.
private struct ZonePicker: View {
    let chosen: String?
    let close: () -> Void
    let choose: (String?) -> Void

    struct Zone: Identifiable {
        let id: String
        let label: String
        let offset: String
        /// What a search matches, lowercased once.
        let searched: String
    }

    @State private var query = ""
    /// Offsets as of opening, so they follow summer time.
    @State private var zones: [Zone] = []

    /// "America/New York".
    static func label(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: " ")
    }

    static var automatic: String { "Automatic · \(TimeZone.current.identifier)" }

    var body: some View {
        let query = query.trimmed.lowercased()
        let matches = query.isEmpty ? zones : zones.filter { $0.searched.contains(query) }
        Panel("Time zone", compact: true, close: close) {
            FormTextField(
                label: "Search time zones", prompt: "Search cities or GMT+…", text: $query,
                systemImage: "magnifyingglass", focusOnAppear: true
            )
            .onSubmit { if !query.isEmpty, let first = matches.first { choose(first.id) } }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if query.isEmpty {
                        ZoneRow(title: "Automatic", detail: "\(TimeZone.current.identifier) · \(TimeZoneOffset.format(.current))",
                                checked: chosen == nil) { choose(nil) }
                        Theme.divider.frame(height: 1).padding(.vertical, 4)
                        SectionLabel("All time zones")
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                    }
                    ForEach(matches) { zone in
                        ZoneRow(title: zone.label, detail: zone.offset, checked: zone.id == chosen) { choose(zone.id) }
                    }
                    if matches.isEmpty {
                        Text("No time zone matches.")
                            .font(Theme.font(12))
                            .foregroundStyle(Theme.secondaryText)
                            .padding(8)
                    }
                }
            }
            .frame(height: 300)
            // The rows' own inset lines their text up with the field's.
            .padding(.horizontal, -8)
        }
        .onAppear {
            zones = TimeZone.knownTimeZoneIdentifiers.compactMap { id in
                TimeZone(identifier: id).map { zone in
                    let label = Self.label(id), offset = TimeZoneOffset.format(zone)
                    return Zone(id: id, label: label, offset: offset, searched: "\(label) \(offset)".lowercased())
                }
            }
        }
    }
}

private struct ZoneRow: View {
    let title: String
    let detail: String
    let checked: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12))
                    .opacity(checked ? 1 : 0)
                    .frame(width: 16)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(detail)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            .font(Theme.font(13))
            .monospacedDigit()
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(hovering ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(checked ? .isSelected : [])
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
                    .buttonStyle(.peel(.primary))
            case .allowed, .denied:
                Button("System Settings…") { model.openNotificationSettings() }
                    .buttonStyle(.peel(.outline))
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
                            problem = PeelError.problem(error, couldNot: "change the setting")
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

/// Sign-ins and site data from pages opened in Peel's web pane: this
/// profile's own store, cleared in place.
private struct WebsiteDataRow: View {
    @Environment(AppModel.self) private var model
    @State private var cleared = false

    var body: some View {
        SettingsRow("Website data") {
            Text(cleared ? "Cleared." : "Sign-ins, cookies and storage of pages opened in Peel, kept for this account only.")
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondaryText)
        } trailing: {
            InlineConfirm(trigger: "Clear…", prompt: "Sign out of every site?", confirm: "Clear") {
                await model.web.clearWebsiteData()
                cleared = true
            }
        }
    }
}

// MARK: - Building blocks

private let settingsLabelWidth: CGFloat = 150
private let settingsRowPadding: CGFloat = 12
private let settingsRowSpacing: CGFloat = 12

/// A titled group of Account rows on a raised card, a hairline between rows.
private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(Theme.font(11, .semibold))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 4)
            Group(subviews: content) { rows in
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        if row.id != rows.first?.id { Theme.divider.frame(height: 1) }
                        row
                    }
                }
            }
            .formCard()
        }
        .padding(.top, 12)
    }
}

/// A row of an Account section: the label column (`FormLabel`), the value
/// beside it, and an optional action on the right. The page is wider than
/// a popover, so its value reads left, by its notes.
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
            FormLabel(label)
                .frame(width: settingsLabelWidth, alignment: .leading)
            value
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, settingsRowPadding)
        .padding(.vertical, 9)
        .frame(minHeight: 44)
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.init(label, value: value, trailing: { EmptyView() })
    }
}
